module MakieExt

using MyObservables
import MyObservables: AbstractNode, to_obs
import Makie
import Makie.ComputePipeline: add_input!, ComputeGraph

Makie.value_convert(x::AbstractNode) = to_obs(x)

function add_input!(attr::ComputeGraph, k::Symbol, node::AbstractNode)
    add_input!(attr, k, to_obs(node))
end

function add_input!(f, attr::ComputeGraph, k::Symbol, node::AbstractNode)
    add_input!(f, attr, k, to_obs(node))
end

# Block attributes (Axis title, etc.) dispatch on ::Observable in init_observable!
function Makie.init_observable!(@nospecialize(block), key::Symbol, @nospecialize(OT), value::AbstractNode)
    Makie.init_observable!(block, key, OT, to_obs(value))
end

end # module
