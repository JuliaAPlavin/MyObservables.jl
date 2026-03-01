using GLMakie

fig = Figure()
ax = Axis(fig[1, 1])
amp = Slider(fig[2, 1], range=0.1:0.1:3.0).value
freq = Slider(fig[3, 1], range=0.1:0.1:5.0).value

xs = LinRange(0, 4π, 200)
ys = @lift $amp .* sin.($freq .* xs)
lines!(ax, xs, ys)

display(fig)
