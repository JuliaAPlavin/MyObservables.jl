using GLMakie
using GLMakie.ComputePipeline: ComputeGraph, add_input!, register_computation!

fig = Figure()
ax = Axis(fig[1, 1])
n = Slider(fig[2, 1], range=10:500).value

graph = ComputeGraph()
add_input!(graph, :n, n)
register_computation!(graph, [:n], [:xs]) do inputs, changed, cached
    (LinRange(0, 10, inputs.n),)
end
register_computation!(graph, [:n], [:ys]) do inputs, changed, cached
    (sin.(LinRange(0, 10, inputs.n)),)
end
register_computation!(graph, [:xs, :ys], [:colors]) do inputs, changed, cached
    (inputs.xs .+ inputs.ys,)
end
scatter!(ax, graph[:xs], graph[:ys], color=graph[:colors])
# works correctly ✓

display(fig)
