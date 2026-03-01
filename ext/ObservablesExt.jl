module ObservablesExt

using MyObservables
import MyObservables: AbstractNode, Signal, Computed, EffectNode, Runtime
import Observables: Observable

function MyObservables.to_observable(node::Union{Signal{T},Computed{T}}) where {T}
    rt = node.runtime
    obs = Observable{T}(node[])
    e = effect!(rt) do
        obs[] = node[]
    end
    rt.bridges[objectid(obs)] = e
    return obs
end

function MyObservables.dispose_bridge!(rt::Runtime, obs::Observable)
    id = objectid(obs)
    e = rt.bridges[id]::EffectNode
    delete!(rt.bridges, id)
    dispose!(e)
    return nothing
end

end # module
