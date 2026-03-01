using MyObservables
using GLMakie

rt = Runtime()
n = signal(rt, 100)
data = computed(rt) do
    [(i, sin(0.1*i)) for i in 0:n[]]
end

xs = computed(rt) do
    first.(data[])
end
ys = computed(rt) do
    last.(data[])
end

obs_xs = to_observable(xs)
obs_ys = to_observable(ys)

fig = Figure()
ax = Axis(fig[1, 1])
scatter!(ax, obs_xs, obs_ys; markersize=20)

display(fig)

for i in 1:100
    n[] = i
    sleep(0.1)
end
