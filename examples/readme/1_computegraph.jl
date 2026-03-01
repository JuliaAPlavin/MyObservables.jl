using GLMakie
using Makie.ComputePipeline: ComputeGraph, add_input!, register_computation!

fig = Figure()
ax = Axis(fig[1, 1])
amp = Slider(fig[2, 1], range=0.1:0.1:3.0, startvalue=1.0).value
freq = Slider(fig[3, 1], range=0.1:0.1:5.0, startvalue=1.0).value

xs = LinRange(0, 4π, 200)
graph = ComputeGraph()
add_input!(graph, :amp, amp)
add_input!(graph, :freq, freq)
register_computation!(graph, [:amp, :freq], [:ys]) do inputs, changed, cached
    (inputs.amp .* sin.(inputs.freq .* xs),)
end
lines!(ax, xs, graph[:ys])
