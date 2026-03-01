using GLMakie

t = Observable(0.0)

# Diamond split: two branches from same source
branch_a = @lift [$t + i for i in 1:10]
branch_b = @lift [sin($t + i) for i in 1:10]

# Diamond join: expensive calculation using both branches
calc_count = Ref(0)
result = @lift begin
    calc_count[] += 1
    println("expensive calculation #$(calc_count[])")
    $branch_a .* $branch_b
end

fig = Figure()
ax = Axis(fig[1, 1]; title="Observables: push-based, redundant calculations on diamond")
lines!(ax, result)

display(fig)

for i in 1:60
    t[] = i * 0.1
    sleep(0.1)
end
println("Total expensive calculations: $(calc_count[]) (expected: $(1 + 60*2), i.e. 2 per update)")
