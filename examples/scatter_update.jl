using MyObservables
using MyObservables: @lift
using GLMakie

n = signal(Runtime(), 100)
data = @lift [(i, sin(0.1*i)) for i in 0:$n]

xs = @lift first.($data)
ys = @lift last.($data)

obs_xs = to_obs(xs)
obs_ys = to_obs(ys)

fig = Figure()
ax = Axis(fig[1, 1])
scatter!(ax, obs_xs, obs_ys; markersize=20)

display(fig)

for i in 1:100
    n[] = i
    sleep(0.1)
end
