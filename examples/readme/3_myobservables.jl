using GLMakie
using MyObservables
using MyObservables: @lift

fig = Figure()
ax = Axis(fig[1, 1])
active = Toggle(fig[2, 1], active=false).active |> from_obs
freq = Slider(fig[3, 1], range=0.1:0.1:5.0).value |> from_obs

xs = LinRange(0, 4π, 200)
calc_count = Ref(0)
analysis = @lift begin
    calc_count[] += 1
    cumsum(sin.($freq .* xs)) ./ (1:length(xs))
end
ys = @lift $active ? $analysis : sin.(xs)
lines!(ax, xs, ys)
# Toggle OFF, move freq 100 times → calc_count = 0!
