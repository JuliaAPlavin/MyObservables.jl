using GLMakie
using Makie.ComputePipeline: ComputeGraph, add_input!, register_computation!

fig = Figure()
ax = Axis(fig[1, 1])
active = Toggle(fig[2, 1], active=false).active
freq = Slider(fig[3, 1], range=0.1:0.1:5.0).value

xs = LinRange(0, 4π, 200)
graph = ComputeGraph()
add_input!(graph, :active, active)
add_input!(graph, :freq, freq)

calc_count = Ref(0)
register_computation!(graph, [:freq], [:analysis]) do inputs, changed, cached
    calc_count[] += 1
    (cumsum(sin.(inputs.freq .* xs)) ./ (1:length(xs)),)
end
register_computation!(graph, [:active, :analysis], [:ys]) do inputs, changed, cached
    inputs.active ? (inputs.analysis,) : (sin.(xs),)
end
lines!(ax, xs, graph[:ys])
# Toggle OFF, move freq 100 times → calc_count = 100
