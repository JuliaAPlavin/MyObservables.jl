module ObservablesExt

using MyObservables
import MyObservables: AbstractNode, Signal, Computed, EffectNode, Runtime
import Observables: Observable, on, off

# ── to_obs: MyObservables → Observable ────────────────────────────────
function MyObservables.to_obs(node::Union{Signal{T},Computed{T}}) where {T}
    rt = node.runtime
    obs = Observable{T}(node[])
    obs_weak = WeakRef(obs)
    e = effect!(rt) do
        o = obs_weak.value
        o === nothing && return
        o[] = node[]
    end
    rt.to_bridges[obs] = e
    return obs
end

# ── from_obs: Observable → MyObservables Signal ──────────────────────
MyObservables.from_obs(obs::Observable) = MyObservables.from_obs(obs, MyObservables._GLOBAL_RT[])

function MyObservables.from_obs(obs::Observable{T}, rt::Runtime) where {T}
    s = signal(rt, T, obs[])
    obsfunc = on(obs) do val
        s[] = val
    end
    rt.from_bridges[obs] = obsfunc
    return s
end

# ── dispose_bridge!: cleanup for both directions ─────────────────────
function MyObservables.dispose_bridge!(rt::Runtime, obs::Observable)
    if haskey(rt.to_bridges, obs)
        e = rt.to_bridges[obs]::EffectNode
        delete!(rt.to_bridges, obs)
        dispose!(e)
    end
    if haskey(rt.from_bridges, obs)
        obsfunc = rt.from_bridges[obs]
        delete!(rt.from_bridges, obs)
        off(obs, obsfunc)
    end
    return nothing
end

end # module
