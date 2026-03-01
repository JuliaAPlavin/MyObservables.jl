using GLMakie

fig = Figure()
ax = Axis(fig[1, 1])
n = Slider(fig[2, 1], range=10:500).value

xs = @lift LinRange(0, 10, $n)
ys = @lift sin.(LinRange(0, 10, $n))
colors = @lift $xs .+ $ys
scatter!(ax, xs, ys, color=colors)
# DimensionMismatch on slider move ✗

display(fig)
