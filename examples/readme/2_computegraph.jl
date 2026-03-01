using GLMakie
using Makie.ComputePipeline: ComputeGraph, add_input!, register_computation!

fig = Figure()
ax = Axis(fig[1, 1])
phase = Slider(fig[2, 1], range=0:0.1:2π, startvalue=0.0).value

xs = LinRange(0, 4π, 200)
graph = ComputeGraph()
add_input!(graph, :phase, phase)
register_computation!(graph, [:phase], [:curve_a]) do inputs, changed, cached
    (sin.(xs .+ inputs.phase),)
end
register_computation!(graph, [:phase], [:curve_b]) do inputs, changed, cached
    (cos.(xs .+ inputs.phase),)
end
register_computation!(graph, [:phase], [:curve_c]) do inputs, changed, cached
    (sin.(2 .* xs .+ inputs.phase),)
end

calc_count = Ref(0)
register_computation!(graph, [:curve_a, :curve_b, :curve_c], [:combined]) do inputs, changed, cached
    calc_count[] += 1
    (inputs.curve_a .+ inputs.curve_b .* inputs.curve_c,)
end
lines!(ax, xs, graph[:combined])
# Moving phase slider: calc_count increases by 1 per update
