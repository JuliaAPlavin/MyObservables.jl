using GLMakie

n = Observable(100)
data = @lift [(i, sin(0.1*i)) for i in 0:$n]
xs = @lift first.($data)
ys = @lift last.($data)
# color = @lift $xs .+ $ys

fig = Figure()
ax = Axis(fig[1, 1])
scatter!(ax, xs, ys; markersize=20)
# scatter!(ax, xs, ys; color, markersize=20)

display(fig)

for i in 1:100
    n[] = i
    sleep(0.1)
end
