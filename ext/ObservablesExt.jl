module ObservablesExt

using MyObservables
import MyObservables: AbstractNode, Signal, Computed, EffectNode, Runtime
import Observables: Observable, on, off

# ── to_obs: MyObservables → Observable ────────────────────────────────
function MyObservables.to_obs(node::Union{Signal{T},Computed{T}}) where {T}
    rt = node.runtime
    obs = Observable{T}(node[])
    e = effect!(rt) do
        obs[] = node[]
    end
    rt.bridges[objectid(obs)] = e
    return obs
end

# ── from_obs: Observable → MyObservables Signal ──────────────────────
const _from_obs_listeners = Dict{UInt64, Any}()

function MyObservables.from_obs(obs::Observable{T}, rt::Runtime) where {T}
    s = signal(rt, obs[])
    obsfunc = on(obs) do val
        s[] = val
    end
    _from_obs_listeners[objectid(obs)] = obsfunc
    return s
end

# ── dispose_bridge!: cleanup for both directions ─────────────────────
function MyObservables.dispose_bridge!(rt::Runtime, obs::Observable)
    id = objectid(obs)
    if haskey(rt.bridges, id)
        e = rt.bridges[id]::EffectNode
        delete!(rt.bridges, id)
        dispose!(e)
    end
    if haskey(_from_obs_listeners, id)
        obsfunc = _from_obs_listeners[id]
        delete!(_from_obs_listeners, id)
        off(obs, obsfunc)
    end
    return nothing
end

end # module
