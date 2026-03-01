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
    to_bridges::WeakKeyDict{Any,Any}      # Observable → EffectNode
    from_bridges::WeakKeyDict{Any,Any}    # Observable → ObserverFunction
    Runtime() = new(nothing, AbstractNode[], 0, WeakKeyDict{Any,Any}(), WeakKeyDict{Any,Any}())
end

# ── Signal ──────────────────────────────────────────────────────────
mutable struct Signal{T} <: AbstractNode
    const runtime::Runtime
    value::T
    version::UInt64
    const users::Set{AbstractNode}
    const skip_equal::Bool
end

signal(rt::Runtime, value::T; skip_equal::Bool=false) where {T} = Signal{T}(rt, value, UInt64(1), Set{AbstractNode}(), skip_equal)

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

value_changed(old, new, skip_equal::Bool) =
    old === new ? false :
    !skip_equal ? true :
    !isequal(old, new)

# ── Lazy pull: check whether any dep version changed ──────────────
function deps_changed!(node::AbstractNode)::Bool
    length(node.deps) != length(node.dep_versions) && return true
    for (dep, dep_version) in zip(node.deps, node.dep_versions)
        if dep isa Computed && dep.state == DIRTY
            update!(dep)
        end
        node_version(dep) != dep_version && return true
    end
    return false
end

# ── Tracked execution: run f() with dependency recording ──────────
function execute_tracked!(f, node::AbstractNode)
    rt = node.runtime
    old_deps = node.deps
    node.deps = AbstractNode[]
    prev = rt.current
    rt.current = node
    try
        result = f()
        cleanup_stale_deps!(node, old_deps)
        unique!(node.deps)
        node.dep_versions = map(node_version, node.deps)
        return result
    catch
        new_partial = node.deps
        node.deps = old_deps
        cleanup_stale_deps!(node, new_partial)
        rethrow()
    finally
        rt.current = prev
    end
end

# ── Remove node from all its deps' user sets ──────────────────────
function remove_from_deps!(node::AbstractNode)
    for dep in node.deps
        delete!(dep.users, node)
        if dep isa Computed && isempty(dep.users)
            unsubscribe!(dep)
        end
    end
    empty!(node.deps)
    empty!(node.dep_versions)
end

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

    if isdefined(c, :value) && !deps_changed!(c)
        c.state = CLEAN
        return nothing
    end

    local new_value
    try
        new_value = execute_tracked!(c.f, c)
    catch
        c.state = DIRTY
        rethrow()
    end

    had_value = isdefined(c, :value)
    changed = !had_value || value_changed(c.value, new_value, c.skip_equal)
    c.value = new_value
    c.state = CLEAN
    changed && (c.version += 1)
    return nothing
end

# ── Effect execution ────────────────────────────────────────────────
function run_effect!(e::EffectNode)
    e.disposed && return

    if !isempty(e.dep_versions) && !deps_changed!(e)
        e.state = CLEAN
        return
    end

    execute_tracked!(e.f, e)
    e.state = CLEAN
end

# ── Stale edge cleanup ─────────────────────────────────────────────
function cleanup_stale_deps!(node::AbstractNode, old_deps::Vector{AbstractNode})
    for old in setdiff(old_deps, node.deps)
        delete!(old.users, node)
        if old isa Computed && isempty(old.users)
            unsubscribe!(old)
        end
    end
end

# ── Liveness: unsubscribe cascade ──────────────────────────────────
function unsubscribe!(c::Computed)
    remove_from_deps!(c)
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
    new_value = convert(T, value)
    changed = value_changed(s.value, new_value, s.skip_equal)
    s.value = new_value
    if changed
        s.version += 1
        propagate_dirty!(s)
        maybe_flush!(s.runtime)
    end
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
        try
            run_effect!(e)
        catch
            empty!(rt.pending_effects)
            rethrow()
        end
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
    remove_from_deps!(e)
end

# ── Observable bridge stubs (overridden by ext/ObservablesExt.jl) ──
function to_obs end
function from_obs end
function dispose_bridge! end

include("lift_macro.jl")

end # module
