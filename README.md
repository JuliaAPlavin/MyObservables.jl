# MyObservables.jl

A pull-based reactive system for Julia with automatic dynamic dependency tracking. Integrates with `Observables.jl` and with `Makie.jl` natively.

**Why not just Observables.jl?** Observables.jl is push-based: every change eagerly propagates to all downstream nodes, even through diamond-shaped graphs and unneeded branches, causing redundant work and inconsistent states.

**Why not ComputeGraph.jl?** Makie's `ComputeGraph` is pull-based and avoids diamond glitches, but requires verbose explicit graph manipulation and still can't always skip unused computations.

**`MyObservables.jl`** combines pull-based evaluation with automatic dynamic dependency tracking — diamonds resolve once, unused branches are never computed, and the syntax stays as simple as `@lift`.


### Comparison at Glance


|                            | `Observables.jl`          | `MyObservables.jl`          | `ComputeGraph.jl`           |
|----------------------------|-------------------------|--------------------------|--------------------------|
| **Evaluation model**       | Eager            | Lazy              | Lazy              |
| **Dependency declaration** | Implicit (push wiring)  | Automatic (tracked reads) | Explicit (symbol lists)  |
| **Diamond (N fan-in)**     | N redundant updates ❌    | 1 update ✅                | 1 update ✅                |
| **Diamond consistency**    | Glitchy intermediate states ❌ | Always consistent ✅    | Always consistent ✅       |
| **Conditional deps**       | Always recompute ❌       | Skip unused branches ✅    | Always recompute ❌        |
| **Simple `@lift` syntax**         | Yes ✅                    | Yes ✅         | No ❌                      |

## Examples

All examples below use GLMakie with sliders/toggles as inputs. Imports for each approach:

```julia
# Observables.jl — built into Makie, nothing extra needed
using GLMakie

# ComputeGraph — Makie's internal compute pipeline
using GLMakie
using GLMakie.ComputePipeline: ComputeGraph, add_input!, register_computation!

# MyObservables
using GLMakie
using MyObservables
using MyObservables: @lift
```

### 1. Simple Data Flow

Two sliders control amplitude and frequency of a sine curve. All three approaches produce identical results. Observables and MyObservables share the same `@lift` syntax; ComputeGraph requires explicit graph construction.

<table>
<tr>
<th>Observables.jl ✅</th>
<th>MyObservables.jl ✅</th>
<th>ComputeGraph.jl ✅</th>
</tr>
<tr>
<td>

```julia
fig = Figure()
ax = Axis(fig[1, 1])
amp = Slider(fig[2, 1], range=0.1:0.1:3.0).value
freq = Slider(fig[3, 1], range=0.1:0.1:5.0).value

xs = LinRange(0, 4π, 200)
ys = @lift $amp .* sin.($freq .* xs)
lines!(ax, xs, ys)
```

</td>
<td>

```julia
fig = Figure()
ax = Axis(fig[1, 1])
amp = Slider(fig[2, 1], range=0.1:0.1:3.0).value |> from_obs
freq = Slider(fig[3, 1], range=0.1:0.1:5.0).value |> from_obs

xs = LinRange(0, 4π, 200)
ys = @lift $amp .* sin.($freq .* xs)
lines!(ax, xs, ys)
```

</td>
<td>

```julia
fig = Figure()
ax = Axis(fig[1, 1])
amp = Slider(fig[2, 1], range=0.1:0.1:3.0).value
freq = Slider(fig[3, 1], range=0.1:0.1:5.0).value

xs = LinRange(0, 4π, 200)
graph = ComputeGraph()
add_input!(graph, :amp, amp)
add_input!(graph, :freq, freq)
register_computation!(graph, [:amp, :freq], [:ys]) do inputs, changed, cached
    (inputs.amp .* sin.(inputs.freq .* xs),)
end
lines!(ax, xs, graph[:ys])
```

</td>
</tr>
</table>

### 2. Diamond Dependency

One slider feeds three intermediate computations that merge into a single expensive result. With Observables.jl, each branch independently pushes into `combined`, causing it to recompute **3 times per slider move**. ComputeGraph and MyObservables resolve the diamond in a single computation.

```
        phase
       /  |  \
  curve_a  curve_b  curve_c
       \   |   /
       combined  ← expensive, tracked by calc_count
```

<table>
<tr>
<th>Observables.jl ❌</th>
<th>MyObservables.jl ✅</th>
<th>ComputeGraph.jl ✅</th>
</tr>
<tr>
<td>

```julia
fig = Figure()
ax = Axis(fig[1, 1])
phase = Slider(fig[2, 1], range=0:0.1:2π).value

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
# calc_count increases by 3 per update ✗
```

</td>
<td>

```julia
fig = Figure()
ax = Axis(fig[1, 1])
phase = Slider(fig[2, 1], range=0:0.1:2π).value |> from_obs

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
# calc_count increases by 1 per update ✓
```

</td>
<td>

```julia
fig = Figure()
ax = Axis(fig[1, 1])
phase = Slider(fig[2, 1], range=0:0.1:2π).value

xs = LinRange(0, 4π, 200)
graph = ComputeGraph()
add_input!(graph, :phase, phase)
register_computation!(graph, [:phase], [:curve_a]) do inputs, changed, cached
    (sin.(xs .+ inputs.phase),)
end
register_computation!(graph, [:phase], [:curve_b]) do inputs, changed, cached
    (cos.(xs .+ inputs.phase),)
end
register_computation!(graph, [:phase], [:curve_c]) do inputs, changed, cached
    (sin.(2 .* xs .+ inputs.phase),)
end

calc_count = Ref(0)
register_computation!(graph, [:curve_a, :curve_b, :curve_c], [:combined]) do inputs, changed, cached
    calc_count[] += 1
    (inputs.curve_a .+ inputs.curve_b .* inputs.curve_c,)
end
lines!(ax, xs, graph[:combined])
# calc_count increases by 1 per update ✓
```

</td>
</tr>
</table>

### 3. Conditional Dependencies

A toggle controls whether an expensive analysis runs. When the toggle is OFF, only a cheap default is shown. With Observables.jl and ComputeGraph, `analysis` recomputes whenever `freq` changes — both treat `freq` as a static dependency regardless of toggle state. With MyObservables, dependencies are tracked dynamically: when the toggle is OFF, `analysis` is never read, so it unsubscribes from `freq` entirely.

<table>
<tr>
<th>Observables.jl ❌</th>
<th>MyObservables.jl ✅</th>
<th>ComputeGraph.jl ❌</th>
</tr>
<tr>
<td>

```julia
fig = Figure()
ax = Axis(fig[1, 1])
active = Toggle(fig[2, 1], active=false).active
freq = Slider(fig[3, 1], range=0.1:0.1:5.0).value

xs = LinRange(0, 4π, 200)
calc_count = Ref(0)
analysis = @lift begin
    calc_count[] += 1
    cumsum(sin.($freq .* xs)) ./ (1:length(xs))
end
ys = @lift $active ? $analysis : sin.(xs)
lines!(ax, xs, ys)
# toggle OFF, mass freq 100× → calc_count = 100 ✗
```

</td>
<td>

```julia
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
# toggle OFF, move freq 100× → calc_count = 0 ✓
```

</td>
<td>

```julia
fig = Figure()
ax = Axis(fig[1, 1])
active = Toggle(fig[2, 1], active=false).active
freq = Slider(fig[3, 1], range=0.1:0.1:5.0).value

xs = LinRange(0, 4π, 200)
graph = ComputeGraph()
add_input!(graph, :active, active)
add_input!(graph, :freq, freq)

calc_count = Ref(0)
register_computation!(graph, [:freq], [:analysis]) do inputs, changed, cached
    calc_count[] += 1
    (cumsum(sin.(inputs.freq .* xs)) ./ (1:length(xs)),)
end
register_computation!(graph, [:active, :analysis], [:ys]) do inputs, changed, cached
    inputs.active ? (inputs.analysis,) : (sin.(xs),)
end
lines!(ax, xs, graph[:ys])
# toggle OFF, move freq 100× → calc_count = 100 ✗
```

</td>
</tr>
</table>

### 4. Variable-Length Diamond

A slider controls the number of scatter points. Coordinates and colors are computed independently from the same `n`, and a derived quantity combines them — a diamond where array lengths must match. With Observables.jl, the first branch updates before the second, causing a **DimensionMismatch crash**. ComputeGraph and MyObservables resolve all branches before the merge, so lengths are always consistent.

```
       n
      / \
    xs   ys
      \ /
    colors = xs .+ ys  ← crashes if lengths differ
```

<table>
<tr>
<th>Observables.jl ❌</th>
<th>MyObservables.jl ✅</th>
<th>ComputeGraph.jl ✅</th>
</tr>
<tr>
<td>

```julia
fig = Figure()
ax = Axis(fig[1, 1])
n = Slider(fig[2, 1], range=10:500).value

xs = @lift LinRange(0, 10, $n)
ys = @lift sin.(LinRange(0, 10, $n))
colors = @lift $xs .+ $ys
scatter!(ax, xs, ys, color=colors)
# DimensionMismatch on slider move ✗
```

</td>
<td>

```julia
fig = Figure()
ax = Axis(fig[1, 1])
n = Slider(fig[2, 1], range=10:500).value |> from_obs

xs = @lift LinRange(0, 10, $n)
ys = @lift sin.(LinRange(0, 10, $n))
colors = @lift $xs .+ $ys
scatter!(ax, xs, ys, color=colors)
# works correctly ✓
```

</td>
<td>

```julia
fig = Figure()
ax = Axis(fig[1, 1])
n = Slider(fig[2, 1], range=10:500).value

graph = ComputeGraph()
add_input!(graph, :n, n)
register_computation!(graph, [:n], [:xs]) do inputs, changed, cached
    (LinRange(0, 10, inputs.n),)
end
register_computation!(graph, [:n], [:ys]) do inputs, changed, cached
    (sin.(LinRange(0, 10, inputs.n)),)
end
register_computation!(graph, [:xs, :ys], [:colors]) do inputs, changed, cached
    (inputs.xs .+ inputs.ys,)
end
scatter!(ax, graph[:xs], graph[:ys], color=graph[:colors])
# works correctly ✓
```

</td>
</tr>
</table>
