using TestItems
using TestItemRunner
@run_package_tests


@testitem "_" begin
    import Aqua
    Aqua.test_all(MyObservables)

    import CompatHelperLocal as CHL
    CHL.@check()
end

@testitem "signal basics" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 10)
    @test s[] == 10
    s[] = 20
    @test s[] == 20
end

@testitem "computed basics" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 3)
    c = computed(rt) do
        s[] * 2
    end

    # computed is lazy — not yet pulled, so no value until an effect or manual read
    # but getindex triggers pull
    log = Int[]
    e = effect!(rt) do
        push!(log, c[])
    end
    @test log == [6]

    s[] = 5
    @test log == [6, 10]
end

@testitem "computed caching" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 1)
    call_count = Ref(0)
    c = computed(rt) do
        call_count[] += 1
        s[] * 10
    end

    e = effect!(rt) do
        c[]
        c[]  # read twice in same effect
    end
    @test call_count[] == 1  # computed ran only once

    s[] = 2
    @test call_count[] == 2  # recomputed once
end

@testitem "effect runs on creation" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 42)
    log = Int[]
    e = effect!(rt) do
        push!(log, s[])
    end
    @test log == [42]
end

@testitem "diamond graph — glitch-free" begin
    using MyObservables

    rt = Runtime()
    a = signal(rt, 1)

    b = computed(rt) do
        a[] * 10
    end

    c = computed(rt) do
        a[] + 1
    end

    results = Int[]
    e = effect!(rt) do
        push!(results, b[] + c[])
    end

    @test results == [12]  # 10*1 + 1+1
    a[] = 2
    @test results == [12, 23]  # 10*2 + 2+1
    a[] = 3
    @test results == [12, 23, 34]  # 10*3 + 3+1
end

@testitem "dynamic dependencies" begin
    using MyObservables

    rt = Runtime()
    toggle = signal(rt, true)
    x = signal(rt, 10)
    y = signal(rt, 20)

    val = computed(rt) do
        toggle[] ? x[] : y[]
    end

    log = Int[]
    e = effect!(rt) do
        push!(log, val[])
    end

    @test log == [10]

    y[] = 99  # y is not a dep right now
    @test log == [10]

    toggle[] = false  # switches dep to y
    @test log == [10, 99]

    x[] = 999  # x is no longer a dep
    @test log == [10, 99]

    y[] = 7
    @test log == [10, 99, 7]
end

@testitem "batching" begin
    using MyObservables

    rt = Runtime()
    a = signal(rt, 1)
    b = signal(rt, 2)

    runs = Int[]
    e = effect!(rt) do
        push!(runs, a[] + b[])
    end

    @test runs == [3]

    batch(rt) do
        a[] = 10
        b[] = 20
    end
    @test runs == [3, 30]  # effect ran once, not twice
end

@testitem "dispose and liveness" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 0)
    c = computed(rt) do
        s[] ^ 2
    end

    log = Int[]
    e = effect!(rt) do
        push!(log, c[])
    end

    @test log == [0]
    s[] = 3
    @test log == [0, 9]

    dispose!(e)
    s[] = 5
    @test log == [0, 9]  # no more updates

    # c should have no users and be unsubscribed
    @test isempty(c.users)
    @test isempty(c.deps)
end

@testitem "equal value suppression" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 1)

    # Default: always propagate even when value not === (but ==)
    c_default = computed(rt) do
        s[] > 0 ? [1] : [0]
    end
    log_default = Vector{Int}[]
    e1 = effect!(rt) do
        push!(log_default, c_default[])
    end
    @test log_default == [[1]]
    s[] = 2  # c returns a new [1] — not === to previous
    @test log_default == [[1], [1]]  # effect re-runs (always propagate)

    # Opt-in: skip_equal suppresses when value isequal
    s[] = 3
    c_skip = computed(rt; skip_equal=true) do
        s[] > 0 ? [1] : [0]
    end
    log_skip = Vector{Int}[]
    e2 = effect!(rt) do
        push!(log_skip, c_skip[])
    end
    @test log_skip == [[1]]
    s[] = 4  # c_skip returns new [1] — isequal to previous
    @test log_skip == [[1]]  # effect suppressed
    s[] = -1  # c_skip now returns [0] — value changed
    @test log_skip == [[1], [0]]  # effect runs
end

@testitem "signal skip_equal" begin
    using MyObservables

    rt = Runtime()

    # Default: always propagate
    s_default = signal(rt, [1])
    log_default = Vector{Int}[]
    effect!(rt) do
        push!(log_default, s_default[])
    end
    @test log_default == [[1]]
    s_default[] = [1]  # isequal but not ===
    @test log_default == [[1], [1]]  # effect re-runs

    # skip_equal: suppress when isequal
    s_skip = signal(rt, [1]; skip_equal=true)
    log_skip = Vector{Int}[]
    effect!(rt) do
        push!(log_skip, s_skip[])
    end
    @test log_skip == [[1]]
    s_skip[] = [1]  # isequal to previous
    @test log_skip == [[1]]  # effect suppressed
    s_skip[] = [2]  # value changed
    @test log_skip == [[1], [2]]  # effect runs
end

@testitem "lazy pull skips unused stale deps" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 1)
    toggle = signal(rt, true)

    a_count = Ref(0)
    expensive_a = computed(rt) do
        a_count[] += 1
        s[] * 1000
    end

    b_count = Ref(0)
    expensive_b = computed(rt) do
        b_count[] += 1
        s[] * 2000
    end

    selector = computed(rt) do
        toggle[] ? expensive_a[] : expensive_b[]
    end

    log = Int[]
    e = effect!(rt) do
        push!(log, selector[])
    end

    @test log == [1000]
    @test a_count[] == 1
    @test b_count[] == 0

    a_count[] = 0
    # Switch branch AND change data: expensive_a should NOT be recomputed
    batch(rt) do
        toggle[] = false
        s[] = 2
    end
    @test log == [1000, 4000]
    @test a_count[] == 0  # no longer needed — lazy pull skipped it
    @test b_count[] == 1
end

@testitem "error recovery in computed" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 1)
    fail = Ref(true)

    c = computed(rt) do
        fail[] && error("boom")
        s[] * 2
    end

    # First read throws because fail[] is true
    @test_throws ErrorException c[]

    # Node should recover — not be stuck in COMPUTING
    fail[] = false
    @test c[] == 2

    # Subsequent updates still work
    s[] = 5
    log = Int[]
    e = effect!(rt) do
        push!(log, c[])
    end
    @test log == [10]
end

@testitem "effect error clears pending effects" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 0)

    log = Int[]
    e_good = effect!(rt) do
        push!(log, s[])
    end
    e_bad = effect!(rt) do
        v = s[]
        v > 0 && error("boom")
    end

    @test log == [0]

    # Use batch + reorder to ensure e_bad runs first in flush
    @test_throws ErrorException batch(rt) do
        s[] = 1
        filter!(e -> e !== e_bad, rt.pending_effects)
        pushfirst!(rt.pending_effects, e_bad)
    end

    # Bug: e_good should NOT linger in pending_effects
    @test isempty(rt.pending_effects)
end

@testitem "cycle detection" begin
    using MyObservables

    rt = Runtime()
    local c
    c = computed(rt) do
        c[]  # self-reference
    end

    @test_throws ErrorException effect!(rt) do
        c[]
    end
end

@testitem "multiple effects" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 1)

    log1 = Int[]
    log2 = Int[]

    e1 = effect!(rt) do
        push!(log1, s[])
    end
    e2 = effect!(rt) do
        push!(log2, s[] * 10)
    end

    @test log1 == [1]
    @test log2 == [10]

    s[] = 2
    @test log1 == [1, 2]
    @test log2 == [10, 20]

    dispose!(e1)
    s[] = 3
    @test log1 == [1, 2]  # stopped
    @test log2 == [10, 20, 30]  # still running
end

@testitem "computed type inference" begin
    using MyObservables

    # let block required: at top-level scope closures don't capture typed fields,
    # so Core.Compiler.return_type can't infer through them.
    let
        rt = Runtime()
        s = signal(rt, 3)

        c_explicit = computed(rt, Float64) do
            Float64(s[])
        end
        @test c_explicit isa MyObservables.Computed{Float64}

        c_inferred = computed(rt) do
            s[] * 2
        end
        @test c_inferred isa MyObservables.Computed{Int}
    end
end

@testitem "Observable bridge (to_obs)" begin
    using MyObservables
    using Observables

    rt = Runtime()
    x = signal(rt, 1.0)
    y = computed(rt) do
        sin(x[])
    end

    obs = to_obs(y)
    @test obs isa Observable
    @test obs[] ≈ sin(1.0)

    x[] = π/2
    @test obs[] ≈ 1.0

    dispose_bridge!(rt, obs)
    x[] = 0.0
    @test obs[] ≈ 1.0  # no longer updated
end

@testitem "Observable bridge (from_obs)" begin
    using MyObservables
    using MyObservables: @lift
    using Observables

    rt = Runtime()

    # Basic: Observable drives a Signal
    obs = Observable(10)
    s = from_obs(obs, rt)
    @test s isa Signal{Int}
    @test s[] == 10

    obs[] = 42
    @test s[] == 42

    # Downstream computed and effects see changes
    c = computed(rt) do
        s[] * 2
    end
    log = Int[]
    e = effect!(rt) do
        push!(log, c[])
    end
    @test log == [84]

    obs[] = 5
    @test c[] == 10
    @test log == [84, 10]

    # Works with @lift
    doubled = @lift $s * 3
    @test doubled[] == 15
    obs[] = 7
    @test doubled[] == 21

    # dispose_bridge! stops updates
    dispose_bridge!(rt, obs)
    obs[] = 999
    @test s[] == 7  # no longer updated
    @test doubled[] == 21

    # Convenience: from_obs without explicit runtime (uses global RT)
    obs2 = Observables.Observable("hello")
    s2 = from_obs(obs2)
    @test s2 isa Signal{String}
    @test s2[] == "hello"
    obs2[] = "world"
    @test s2[] == "world"
end

@testitem "@lift macro" begin
    using MyObservables
    using MyObservables: Observable, @lift, _GLOBAL_RT

    a = Observable(1)
    b = Observable(2)

    c = @lift $a + $b
    @test c isa MyObservables.Computed
    @test c[] == 3

    a[] = 10
    @test c[] == 12

    b[] = 5
    @test c[] == 15

    # complex expression
    x = Observable(3.0)
    y = Observable(4.0)
    hyp = @lift sqrt($x^2 + $y^2)
    @test hyp[] == 5.0
    x[] = 5.0
    y[] = 12.0
    @test hyp[] == 13.0

    # computed inputs
    doubled = @lift $x * 2
    z = @lift $doubled + $y
    @test z[] == 22.0

    # nested property access
    nt = (sig = Observable([1, 2, 3]),)
    len = @lift length($(nt.sig)) + 1
    @test len[] == 4
    nt.sig[] = [1, 2]
    @test len[] == 3

    # with effects
    log = Int[]
    e = effect!(_GLOBAL_RT[]) do
        push!(log, c[])
    end
    @test log == [15]
    a[] = 3
    @test log == [15, 8]
end

@testitem "CairoMakie integration" begin
    using MyObservables
    using CairoMakie
    using CairoMakie.Makie: Point2f

    rt = Runtime()
    data = signal(rt, [(0.0, 0.0), (1.0, 1.0), (2.0, 0.0)])

    xs = computed(rt) do
        first.(data[])
    end
    ys = computed(rt) do
        last.(data[])
    end

    obs_xs = to_obs(xs)
    obs_ys = to_obs(ys)

    fig = Figure()
    ax = Axis(fig[1, 1]; limits=(-1, 3, -2, 2))
    p = scatter!(ax, obs_xs, obs_ys; markersize=20)

    buf1 = copy(colorbuffer(fig))
    @test p[1][] == Point2f[(0, 0), (1, 1), (2, 0)]

    # Update single source signal — both x and y observables update
    data[] = [(0.0, 1.5), (1.0, -1.5), (2.0, 1.5)]
    buf2 = copy(colorbuffer(fig))

    @test p[1][] == Point2f[(0, 1.5), (1, -1.5), (2, 1.5)]
    @test buf1 != buf2
end

@testitem "CairoMakie changing data length" begin
    using MyObservables
    using MyObservables: @lift
    using CairoMakie
    using CairoMakie.Makie: Point2f

    rt = Runtime()
    data = signal(rt, [(0.0, 0.0), (1.0, 1.0)])

    xs = @lift first.($data)
    ys = @lift last.($data)
    colors = @lift last.($data)

    fig = Figure()
    ax = Axis(fig[1, 1]; limits=(-1, 4, -2, 2))
    p = scatter!(ax, xs, ys; color=colors, markersize=20)

    buf1 = copy(colorbuffer(fig))
    @test p[1][] == Point2f[(0, 0), (1, 1)]

    # Add more points — all inputs update atomically via pull-based integration
    data[] = [(0.0, 0.0), (1.0, 1.0), (2.0, -1.0), (3.0, 1.5)]
    buf2 = copy(colorbuffer(fig))

    @test p[1][] == Point2f[(0, 0), (1, 1), (2, -1), (3, 1.5)]
    @test buf1 != buf2
end

@testitem "CairoMakie direct nodes" begin
    using MyObservables
    using MyObservables: @lift
    using CairoMakie
    using CairoMakie.Makie: Point2f

    rt = Runtime()
    data = signal(rt, [(0.0, 0.0), (1.0, 1.0), (2.0, 0.0)])

    xs = @lift first.($data)
    ys = @lift last.($data)
    colors = signal(rt, [:red, :green, :blue])
    title = signal(rt, "initial title")

    fig = Figure()
    ax = Axis(fig[1, 1]; limits=(-1, 3, -2, 2), title=title)
    p = scatter!(ax, xs, ys; markersize=20, color=colors)

    buf1 = copy(colorbuffer(fig))
    @test p[1][] == Point2f[(0, 0), (1, 1), (2, 0)]

    # Update source — plot should reflect new data
    data[] = [(0.0, 1.5), (1.0, -1.5), (2.0, 1.5)]
    buf2 = copy(colorbuffer(fig))
    @test p[1][] == Point2f[(0, 1.5), (1, -1.5), (2, 1.5)]
    @test buf1 != buf2

    # Update color attribute
    colors[] = [:blue, :red, :green]
    buf3 = copy(colorbuffer(fig))
    @test buf2 != buf3

    # Update title attribute
    title[] = "updated title"
    @test ax.title[] == "updated title"

end
