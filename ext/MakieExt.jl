module MakieExt

using MyObservables
import MyObservables: AbstractNode, to_obs
import Makie
import Makie.ComputePipeline
import Makie.ComputePipeline: add_input!, ComputeGraph

# Support ComputePipeline.Computed in lift/@lift
MyObservables._maybe_node(c::ComputePipeline.Computed) = MyObservables.from_obs(Makie.map(identity, c))
MyObservables.to_value(c::ComputePipeline.Computed) = c[]

# Block attributes — independent, keep using to_obs bridge
Makie.value_convert(x::AbstractNode) = to_obs(x)
function Makie.init_observable!(@nospecialize(block), key::Symbol, @nospecialize(OT), value::AbstractNode)
    Makie.init_observable!(block, key, OT, to_obs(value))
end

# Per-graph state: objectid(graph) → (node mapping, effect)
const _graph_state = Dict{UInt64, Tuple{Dict{Symbol, AbstractNode}, MyObservables.EffectNode}}()

function _register_node!(attr::ComputeGraph, k::Symbol, node::AbstractNode)
    gid = objectid(attr)
    rt = node.runtime

    if !haskey(_graph_state, gid)
        mapping = Dict{Symbol, AbstractNode}(k => node)
        # Create effect ONCE — reads from mapping which grows as nodes are added
        e = effect!(rt) do
            pairs = Pair{Symbol, Any}[sym => n[] for (sym, n) in mapping]
            ComputePipeline.update!(attr, pairs)
        end
        _graph_state[gid] = (mapping, e)
    else
        mapping, e = _graph_state[gid]
        mapping[k] = node
        # Re-run effect to pick up new dependency (no disposal!)
        # Clear dep_versions to bypass run_effect!'s version check
        e.state = MyObservables.DIRTY
        empty!(e.dep_versions)
        MyObservables.run_effect!(e)
    end
end

function add_input!(attr::ComputeGraph, k::Symbol, node::AbstractNode)
    add_input!(attr, k, node[])  # create Input with initial plain value
    _register_node!(attr, k, node)
end

function add_input!(f, attr::ComputeGraph, k::Symbol, node::AbstractNode)
    add_input!(f, attr, k, node[])  # create Input with initial value + conversion
    _register_node!(attr, k, node)
end

end # module
