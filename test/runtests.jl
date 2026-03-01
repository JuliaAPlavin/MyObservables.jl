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
    c = computed(rt) do
        s[] > 0 ? :positive : :negative
    end

    log = Symbol[]
    e = effect!(rt) do
        push!(log, c[])
    end

    @test log == [:positive]
    s[] = 2  # c still returns :positive — value unchanged
    @test log == [:positive]  # effect should not re-run
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

@testitem "Observable bridge" begin
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

@testitem "@lift macro" begin
    using MyObservables
    using MyObservables.Lift

    rt = Runtime()
    a = signal(rt, 1)
    b = signal(rt, 2)

    c = @lift($a + $b)
    @test c isa MyObservables.Computed
    @test c[] == 3

    a[] = 10
    @test c[] == 12

    b[] = 5
    @test c[] == 15

    # complex expression
    x = signal(rt, 3.0)
    y = signal(rt, 4.0)
    hyp = @lift(sqrt($x^2 + $y^2))
    @test hyp[] == 5.0
    x[] = 5.0
    y[] = 12.0
    @test hyp[] == 13.0

    # computed inputs
    doubled = computed(rt) do; x[] * 2; end
    z = @lift($doubled + $y)
    @test z[] == 22.0

    # nested property access
    nt = (sig = signal(rt, [1, 2, 3]),)
    len = @lift(length($(nt.sig)) + 1)
    @test len[] == 4
    nt.sig[] = [1, 2]
    @test len[] == 3

    # with effects
    log = Int[]
    e = effect!(rt) do
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
    using CairoMakie
    using CairoMakie.Makie: Point2f

    rt = Runtime()
    data = signal(rt, [(0.0, 0.0), (1.0, 1.0)])

    xs = computed(rt) do
        first.(data[])
    end
    ys = computed(rt) do
        last.(data[])
    end

    obs_xs = to_obs(xs)
    obs_ys = to_obs(ys)

    fig = Figure()
    ax = Axis(fig[1, 1]; limits=(-1, 4, -2, 2))
    p = scatter!(ax, obs_xs, obs_ys; markersize=20)

    buf1 = copy(colorbuffer(fig))
    @test p[1][] == Point2f[(0, 0), (1, 1)]

    # Add more points
    data[] = [(0.0, 0.0), (1.0, 1.0), (2.0, -1.0), (3.0, 1.5)]
    buf2 = copy(colorbuffer(fig))

    @test p[1][] == Point2f[(0, 0), (1, 1), (2, -1), (3, 1.5)]
    @test buf1 != buf2
end
