module MyObservables

export Runtime, Signal, Computed, EffectNode
export signal, computed, effect!, dispose!, batch, to_observable, dispose_bridge!

# ── Node state ──────────────────────────────────────────────────────
@enum NodeState::UInt8 CLEAN=0 DIRTY=1 COMPUTING=2

# ── Abstract base ───────────────────────────────────────────────────
abstract type AbstractNode end

# ── Runtime ─────────────────────────────────────────────────────────
mutable struct Runtime
    current::Union{Nothing,AbstractNode}
    pending_effects::Vector{AbstractNode}
    batch_depth::Int
    bridges::Dict{UInt64,AbstractNode}   # objectid(Observable) → EffectNode
    Runtime() = new(nothing, AbstractNode[], 0, Dict{UInt64,AbstractNode}())
end

# ── Signal ──────────────────────────────────────────────────────────
mutable struct Signal{T} <: AbstractNode
    const runtime::Runtime
    value::T
    const users::Set{AbstractNode}
end

signal(rt::Runtime, value::T) where {T} = Signal{T}(rt, value, Set{AbstractNode}())

# ── Computed ────────────────────────────────────────────────────────
mutable struct Computed{T} <: AbstractNode
    const runtime::Runtime
    const f
    version::UInt64
    state::NodeState
    deps::Vector{AbstractNode}
    const users::Set{AbstractNode}
    value::T

    function Computed{T}(runtime::Runtime, f) where {T}
        new{T}(runtime, f, UInt64(0), DIRTY, AbstractNode[], Set{AbstractNode}())
        # value left #undef
    end
end

function computed(f, rt::Runtime, ::Type{T}) where {T}
    Computed{T}(rt, f)
end

function computed(f, rt::Runtime)
    T = Base.promote_op(f)
    Computed{T}(rt, f)
end

# ── Effect ──────────────────────────────────────────────────────────
mutable struct EffectNode <: AbstractNode
    const runtime::Runtime
    const f
    state::NodeState
    deps::Vector{AbstractNode}
    disposed::Bool
end

function effect!(f, rt::Runtime)
    e = EffectNode(rt, f, DIRTY, AbstractNode[], false)
    run_effect!(e)
    return e
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
    old_deps = c.deps
    c.deps = AbstractNode[]

    prev = rt.current
    rt.current = c
    local new_value
    try
        new_value = c.f()
    finally
        rt.current = prev
    end

    cleanup_stale_deps!(c, old_deps)
    unique!(c.deps)

    had_value = isdefined(c, :value)
    changed = !had_value || !isequal(c.value, new_value)
    c.value = new_value
    c.state = CLEAN
    changed && (c.version += 1)
    return nothing
end

# ── Effect execution ────────────────────────────────────────────────
function run_effect!(e::EffectNode)
    e.disposed && return
    rt = e.runtime
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
end

# ── Observable bridge stubs (overridden by ext/ObservablesExt.jl) ──
function to_observable end
function dispose_bridge! end

end # module
