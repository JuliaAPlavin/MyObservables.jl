module MyObservables

export Runtime, Signal, Computed, EffectNode
export signal, computed, effect!, dispose!, batch, to_obs, from_obs, dispose_bridge!
export runtime

# ── Node state ──────────────────────────────────────────────────────
@enum NodeState::UInt8 CLEAN=0 DIRTY=1 COMPUTING=2

# ── Abstract base ───────────────────────────────────────────────────
abstract type AbstractNode end

# ── Runtime ─────────────────────────────────────────────────────────
mutable struct Runtime
    current::Union{Nothing,AbstractNode}
    pending_effects::Vector{AbstractNode}
    batch_depth::Int
    to_bridges::Dict{UInt64,Any}          # objectid(Observable) → EffectNode
    from_bridges::WeakKeyDict{Any,Any}    # Observable → ObserverFunction
    Runtime() = new(nothing, AbstractNode[], 0, Dict{UInt64,Any}(), WeakKeyDict{Any,Any}())
end

# ── Signal ──────────────────────────────────────────────────────────
mutable struct Signal{T} <: AbstractNode
    const runtime::Runtime
    value::T
    version::UInt64
    const users::Set{AbstractNode}
end

signal(rt::Runtime, value::T) where {T} = Signal{T}(rt, value, UInt64(1), Set{AbstractNode}())

# ── Runtime extraction ────────────────────────────────────────────
function runtime(node::AbstractNode, nodes::AbstractNode...)
    rt = node.runtime
    for n in nodes
        n.runtime === rt || error("Nodes belong to different runtimes")
    end
    return rt
end

# ── Computed ────────────────────────────────────────────────────────
mutable struct Computed{T} <: AbstractNode
    const runtime::Runtime
    const f
    version::UInt64
    state::NodeState
    deps::Vector{AbstractNode}
    dep_versions::Vector{UInt64}
    const users::Set{AbstractNode}
    const skip_equal::Bool
    value::T

    function Computed{T}(runtime::Runtime, f; skip_equal::Bool=false) where {T}
        new{T}(runtime, f, UInt64(0), DIRTY, AbstractNode[], UInt64[], Set{AbstractNode}(), skip_equal)
        # value left #undef
    end
end

function computed(f, rt::Runtime, ::Type{T}; skip_equal::Bool=false) where {T}
    Computed{T}(rt, f; skip_equal)
end

function computed(f, rt::Runtime; skip_equal::Bool=false)
    T = Core.Compiler.return_type(f, Tuple{})
    Computed{T}(rt, f; skip_equal)
end

# ── Effect ──────────────────────────────────────────────────────────
mutable struct EffectNode <: AbstractNode
    const runtime::Runtime
    const f
    state::NodeState
    deps::Vector{AbstractNode}
    dep_versions::Vector{UInt64}
    disposed::Bool
end

function effect!(f, rt::Runtime)
    e = EffectNode(rt, f, DIRTY, AbstractNode[], UInt64[], false)
    run_effect!(e)
    return e
end

# ── Version helper ──────────────────────────────────────────────────
node_version(s::Signal) = s.version
node_version(c::Computed) = c.version

# ── Dependency tracking ─────────────────────────────────────────────
function track!(consumer::AbstractNode, provider::AbstractNode)
    @assert consumer.runtime === provider.runtime "Nodes belong to different runtimes"
    push!(consumer.deps, provider)
    push!(provider.users, consumer)
end

# ── getindex: read + track + pull ───────────────────────────────────
function Base.getindex(s::Signal{T})::T where {T}
    current = s.runtime.current
    current !== nothing && track!(current, s)
    return s.value
end

function Base.getindex(c::Computed{T})::T where {T}
    c.state == COMPUTING && error("Cycle detected: a Computed depends on itself")
    current = c.runtime.current
    current !== nothing && track!(current, c)
    c.state == DIRTY && update!(c)
    return c.value
end

# ── Pull-to-recompute ──────────────────────────────────────────────
function update!(c::Computed)
    c.state == COMPUTING && error("Cycle detected: a Computed depends on itself")
    c.state = COMPUTING
    rt = c.runtime

    # Lazy pull + version check: pull deps one at a time, stop on first change.
    # Remaining dirty deps are pulled lazily by getindex during recompute,
    # avoiding unnecessary updates of deps that dynamic re-tracking may drop.
    if isdefined(c, :value) && length(c.deps) == length(c.dep_versions)
        needs_recompute = false
        for i in eachindex(c.deps)
            dep = c.deps[i]
            dep isa Computed && dep.state == DIRTY && update!(dep)
            if node_version(dep) != c.dep_versions[i]
                needs_recompute = true
                break
            end
        end
        if !needs_recompute
            c.state = CLEAN
            return nothing
        end
    end

    # Re-run with dependency tracking
    old_deps = c.deps
    c.deps = AbstractNode[]

    prev = rt.current
    rt.current = c
    local new_value
    try
        new_value = c.f()
    catch
        new_partial = c.deps
        c.deps = old_deps
        cleanup_stale_deps!(c, new_partial)
        c.state = DIRTY
        rethrow()
    finally
        rt.current = prev
    end

    cleanup_stale_deps!(c, old_deps)
    unique!(c.deps)
    c.dep_versions = map(node_version, c.deps)

    had_value = isdefined(c, :value)
    changed = !had_value || !c.skip_equal || !isequal(c.value, new_value)
    c.value = new_value
    c.state = CLEAN
    changed && (c.version += 1)
    return nothing
end

# ── Effect execution ────────────────────────────────────────────────
function run_effect!(e::EffectNode)
    e.disposed && return
    rt = e.runtime

    # Lazy pull + version check: pull deps one at a time, stop on first change.
    if !isempty(e.dep_versions) && length(e.deps) == length(e.dep_versions)
        needs_rerun = false
        for i in eachindex(e.deps)
            dep = e.deps[i]
            dep isa Computed && dep.state == DIRTY && update!(dep)
            if node_version(dep) != e.dep_versions[i]
                needs_rerun = true
                break
            end
        end
        if !needs_rerun
            e.state = CLEAN
            return
        end
    end

    # Run with dependency tracking
    old_deps = e.deps
    e.deps = AbstractNode[]

    prev = rt.current
    rt.current = e
    try
        e.f()
        e.state = CLEAN
    finally
        rt.current = prev
    end

    cleanup_stale_deps!(e, old_deps)
    unique!(e.deps)
    e.dep_versions = map(node_version, e.deps)
end

# ── Stale edge cleanup ─────────────────────────────────────────────
function cleanup_stale_deps!(node::AbstractNode, old_deps::Vector{AbstractNode})
    new_deps_set = Set(node.deps)
    for old in old_deps
        if old ∉ new_deps_set
            delete!(old.users, node)
            old isa Computed && isempty(old.users) && unsubscribe!(old)
        end
    end
end

# ── Liveness: unsubscribe cascade ──────────────────────────────────
function unsubscribe!(c::Computed)
    for dep in c.deps
        delete!(dep.users, c)
        dep isa Computed && isempty(dep.users) && unsubscribe!(dep)
    end
    empty!(c.deps)
    empty!(c.dep_versions)
    c.state = DIRTY
end

# ── Invalidation propagation ───────────────────────────────────────
function propagate_dirty!(source::AbstractNode)
    queue = collect(source.users)
    while !isempty(queue)
        node = popfirst!(queue)
        if node isa Computed
            node.state == DIRTY && continue
            node.state = DIRTY
            append!(queue, node.users)
        elseif node isa EffectNode
            if !node.disposed && node.state != DIRTY
                node.state = DIRTY
                push!(node.runtime.pending_effects, node)
            end
        end
    end
end

# ── setindex!: write + invalidate + flush ───────────────────────────
function Base.setindex!(s::Signal{T}, value) where {T}
    s.value = convert(T, value)
    s.version += 1
    propagate_dirty!(s)
    maybe_flush!(s.runtime)
    return value
end

# ── Flush pending effects ──────────────────────────────────────────
function maybe_flush!(rt::Runtime)
    rt.batch_depth > 0 && return
    flush!(rt)
end

function flush!(rt::Runtime)
    while !isempty(rt.pending_effects)
        e = popfirst!(rt.pending_effects)
        (e.disposed || e.state != DIRTY) && continue
        run_effect!(e)
    end
end

# ── Batching ────────────────────────────────────────────────────────
function batch(f, rt::Runtime)
    rt.batch_depth += 1
    try
        f()
    finally
        rt.batch_depth -= 1
        maybe_flush!(rt)
    end
end

# ── Dispose ─────────────────────────────────────────────────────────
function dispose!(e::EffectNode)
    e.disposed = true
    filter!(!=(e), e.runtime.pending_effects)
    for dep in e.deps
        delete!(dep.users, e)
        dep isa Computed && isempty(dep.users) && unsubscribe!(dep)
    end
    empty!(e.deps)
    empty!(e.dep_versions)
end

# ── Observable bridge stubs (overridden by ext/ObservablesExt.jl) ──
function to_obs end
function from_obs end
function dispose_bridge! end

include("lift_macro.jl")

end # module
