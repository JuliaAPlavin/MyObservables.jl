using GLMakie
using MyObservables
using MyObservables: @lift

fig = Figure()
ax = Axis(fig[1, 1])
phase = Slider(fig[2, 1], range=0:0.1:2π, startvalue=0.0).value |> from_obs

xs = LinRange(0, 4π, 200)
curve_a = @lift sin.(xs .+ $phase)
curve_b = @lift cos.(xs .+ $phase)
curve_c = @lift sin.(2 .* xs .+ $phase)

calc_count = Ref(0)
combined = @lift begin
    calc_count[] += 1
    $curve_a .+ $curve_b .* $curve_c
end
lines!(ax, xs, combined)
# Moving phase slider: calc_count increases by 1 per update
