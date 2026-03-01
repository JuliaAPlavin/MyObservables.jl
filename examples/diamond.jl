using MyObservables
using GLMakie

rt = Runtime()
t = signal(rt, 0.0)

# Diamond split: two branches from same source
branch_a = computed(rt) do
    [t[] + i for i in 1:10]
end
branch_b = computed(rt) do
    [sin(t[] + i) for i in 1:10]
end

# Diamond join: expensive calculation using both branches
calc_count = Ref(0)
result = computed(rt) do
    calc_count[] += 1
    println("expensive calculation #$(calc_count[])")
    branch_a[] .* branch_b[]
end

obs_result = to_observable(result)

fig = Figure()
ax = Axis(fig[1, 1]; title="MyObservables: pull-based, no redundant calculations")
lines!(ax, obs_result)

display(fig)

for i in 1:60
    t[] = i * 0.1
    sleep(0.1)
end
println("Total expensive calculations: $(calc_count[]) (expected: $(1 + 60), i.e. 1 per update)")
