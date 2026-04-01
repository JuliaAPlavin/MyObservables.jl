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

@testitem "peek (untracked read)" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 10)
    other = signal(rt, 99)

    # peek reads current value without tracking
    c = computed(rt) do
        s[] + peek(other)  # depends on s, NOT on other
    end

    @test c[] == 109

    other[] = 1  # c should NOT recompute — other is not a dep
    @test c[] == 109  # cached, not dirty

    s[] = 20  # c recomputes, picks up other's current value (1)
    @test c[] == 21

    # peek on dirty computed triggers update but doesn't track
    s[] = 30
    log = Int[]
    e = effect!(rt) do
        push!(log, peek(c))  # reads c without tracking
        s[]                   # only depends on s
    end
    @test log == [31]
    s[] = 40
    @test log == [31, 41]  # effect re-runs (s changed), peek(c) returns fresh value

    other[] = 100  # c is not a dep of e, so e doesn't re-run
    @test log == [31, 41]
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

@testitem "error in dep during deps_changed! doesn't poison parent" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 1)
    fail = Ref(false)

    dep = computed(rt) do
        fail[] && error("dep boom")
        s[] * 10
    end

    c = computed(rt) do
        dep[] + 1
    end

    # Establish both with valid values
    @test c[] == 11

    # Now make dep throw and dirty the graph
    fail[] = true
    s[] = 2  # dirties dep and c

    # c[] → update!(c) → sets c.state=COMPUTING → deps_changed!(c) → update!(dep) → throws
    @test_throws ErrorException c[]

    # Fix dep — c should recover, not be stuck in COMPUTING
    fail[] = false
    @test c[] == 21
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

@testitem "computed setindex!" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 3)
    c = computed(rt) do
        s[] * 2
    end

    log = Int[]
    e = effect!(rt) do
        push!(log, c[])
    end
    @test log == [6]

    # Manual override: downstream sees new value, upstream unchanged
    c[] = 99
    @test log == [6, 99]
    @test s[] == 3  # upstream untouched

    # Temporary: upstream change causes recomputation (override gone)
    s[] = 10
    @test log == [6, 99, 20]  # back to s[] * 2

    # Override previously-evaluated computed
    c2 = computed(rt) do
        s[] + 1
    end
    @test c2[] == 11  # establish deps
    log2 = Int[]
    c2[] = 42
    e2 = effect!(rt) do
        push!(log2, c2[])
    end
    @test log2 == [42]

    # Upstream change recomputes (override gone)
    s[] = 5
    @test log2 == [42, 6]

    # Works within batch
    c3 = computed(rt) do
        s[] * 3
    end
    log3 = Int[]
    e3 = effect!(rt) do
        push!(log3, c3[])
    end
    @test log3 == [15]

    batch(rt) do
        c3[] = 100
        s[] = 1  # this dirties c3 again
    end
    # After batch: c3 is dirty from s change, effect pulls fresh value
    @test log3 == [15, 3]  # s[]=1, c3 recomputes to 1*3=3

    # Diamond: set intermediate computed, only downstream updates
    a = signal(rt, 10)
    left = computed(rt) do
        a[] + 1
    end
    right = computed(rt) do
        a[] + 2
    end
    bottom = computed(rt) do
        left[] + right[]
    end

    log4 = Int[]
    e4 = effect!(rt) do
        push!(log4, bottom[])
    end
    @test log4 == [23]  # (10+1) + (10+2)

    left[] = 50  # override left, right and a unchanged
    @test log4 == [23, 62]  # 50 + (10+2)
    @test a[] == 10  # upstream untouched

    # skip_equal respected
    c_skip = computed(rt; skip_equal=true) do
        a[] > 0 ? [1] : [0]
    end
    log5 = Vector{Int}[]
    e5 = effect!(rt) do
        push!(log5, c_skip[])
    end
    @test log5 == [[1]]
    c_skip[] = [1]  # isequal to current value
    @test log5 == [[1]]  # suppressed
    c_skip[] = [2]  # different value
    @test log5 == [[1], [2]]
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

    # f-string support
    using PyFormattedStrings
    v = Observable(1.0)
    t1 = @lift f"abc {$v:0.2f} def"
    @test t1[] == "abc 1.00 def"

    t2 = @lift f"abc {$v:0.2f} def" * "x"
    @test t2[] == "abc 1.00 defx"

    v[] = 2.5
    @test t1[] == "abc 2.50 def"
    @test t2[] == "abc 2.50 defx"

    # type annotation
    a2 = Observable(1)
    b2 = Observable(2)
    c_typed = @lift ($a2 + $b2)::Float64
    @test c_typed isa MyObservables.Computed{Float64}
    @test c_typed[] === 3.0

    # no reactive deps — returns plain value
    @test (@lift 1 + 2) === 3
    plain_a = 10
    @test (@lift $plain_a + 1) === 11
    @test (@lift $plain_a) === 10

    # bare $node
    bare = @lift $x
    @test bare isa MyObservables.Computed
    @test bare[] == 5.0

    # conditional dependency tracking: unused branch not computed
    rt2 = Runtime()
    toggle = signal(rt2, true)
    s2 = signal(rt2, 1)
    a_count = Ref(0)
    expensive_a = computed(rt2) do
        a_count[] += 1
        s2[] * 10
    end
    b_count = Ref(0)
    expensive_b = computed(rt2) do
        b_count[] += 1
        s2[] * 100
    end
    result = @lift $toggle ? $expensive_a : $expensive_b
    @test result[] == 10
    @test a_count[] == 1
    @test b_count[] == 0

    toggle[] = false
    @test result[] == 100
    @test b_count[] == 1
end

@testitem "@lift with Observables.Observable" begin
    using MyObservables
    using MyObservables: @lift, _GLOBAL_RT
    using Observables

    # Basic: Observable directly in @lift
    obs = Observables.Observable(10)
    c = @lift $obs + 1
    @test c isa MyObservables.Computed
    @test c[] == 11
    obs[] = 20
    @test c[] == 21

    # Dedup within single @lift: same observable used twice
    obs2 = Observables.Observable(5)
    c2 = @lift $obs2 + $obs2
    @test c2[] == 10
    obs2[] = 7
    @test c2[] == 14

    # Dedup across @lift calls: same observable yields same Signal
    obs3 = Observables.Observable(1)
    c3a = @lift $obs3 + 10
    c3b = @lift $obs3 * 2
    @test c3a[] == 11
    @test c3b[] == 2
    obs3[] = 5
    @test c3a[] == 15
    @test c3b[] == 10
    # from_obs returns the same signal for the same observable
    @test from_obs(obs3) === from_obs(obs3)
    # single signal means effect fires once per observable update, not twice
    obs5 = Observables.Observable(0)
    c5a = @lift $obs5 + 1
    c5b = @lift $obs5 * 10
    log = Tuple{Int,Int}[]
    e = effect!(_GLOBAL_RT[]) do
        push!(log, (c5a[], c5b[]))
    end
    @test log == [(1, 0)]
    obs5[] = 3
    @test log == [(1, 0), (4, 30)]  # one consistent update, not two

    # Mixed: Observable and AbstractNode
    s = signal(_GLOBAL_RT[], 100)
    obs4 = Observables.Observable(1)
    c4 = @lift $s + $obs4
    @test c4[] == 101
    s[] = 200
    @test c4[] == 201
    obs4[] = 2
    @test c4[] == 202

    # Complex expression
    obs_x = Observables.Observable(3.0)
    obs_y = Observables.Observable(4.0)
    hyp = @lift sqrt($obs_x^2 + $obs_y^2)
    @test hyp[] == 5.0
    obs_x[] = 5.0
    obs_y[] = 12.0
    @test hyp[] == 13.0
end

@testitem "lift function" begin
    using MyObservables
    using MyObservables: lift, _GLOBAL_RT

    rt = Runtime()

    # single node
    s = signal(rt, 5)
    c = lift(x -> 2x, s)
    @test c[] == 10
    s[] = 7
    @test c[] == 14

    # multiple nodes
    a = signal(rt, 3)
    b = signal(rt, 4)
    c2 = lift((x, y) -> x + y, a, b)
    @test c2[] == 7
    a[] = 10
    @test c2[] == 14
    b[] = 1
    @test c2[] == 11

    # mixed node + plain value
    c3 = lift((x, y) -> x * y, a, 100)
    @test c3[] == 1000
    a[] = 2
    @test c3[] == 200

    # no nodes at all — returns plain value
    c4 = lift((x, y) -> x + y, 1, 2)
    @test c4 === 3
    @test !(c4 isa MyObservables.AbstractNode)

    # no arguments at all
    c4b = lift(() -> 42)
    @test c4b === 42

    # skip_equal kwarg
    c5 = lift(x -> x ÷ 10, a; skip_equal=true)
    @test c5[] == 0
    a[] = 5
    @test c5[] == 0
    v1 = c5.version
    a[] = 9
    @test c5.version == v1  # no version bump, value still 0

    # explicit type
    c6 = lift(Float64, (x, y) -> x + y, a, b)
    @test c6 isa MyObservables.Computed{Float64}
    @test c6[] === 10.0

    # explicit type with no nodes — returns plain value
    c7 = lift(Float64, (x, y) -> x + y, 1, 2)
    @test c7 === 3.0
    @test !(c7 isa MyObservables.AbstractNode)
end

@testitem "lift function with Observables" begin
    using MyObservables
    using MyObservables: lift, _GLOBAL_RT
    using Observables

    obs = Observables.Observable(10)
    c = lift(x -> x + 1, obs)
    @test c isa MyObservables.Computed
    @test c[] == 11
    obs[] = 20
    @test c[] == 21

    # mixed Observable + Signal
    s = signal(_GLOBAL_RT[], 100)
    obs2 = Observables.Observable(5)
    c2 = lift((a, b) -> a + b, s, obs2)
    @test c2[] == 105
    s[] = 200
    @test c2[] == 205
    obs2[] = 10
    @test c2[] == 210
end

@testitem "to_value cross-compat" begin
    using MyObservables
    using MyObservables: to_value
    using Observables

    rt = Runtime()

    # MyObservables.to_value unwraps Observables
    obs = Observables.Observable(42)
    @test to_value(obs) == 42

    # MyObservables.to_value still works on nodes
    s = signal(rt, 10)
    @test to_value(s) == 10

    # MyObservables.to_value passes through plain values
    @test to_value(3.14) === 3.14

    # Observables.to_value unwraps MyObservables nodes
    s2 = signal(rt, 99)
    @test Observables.to_value(s2) == 99

    c = computed(rt) do
        s2[] + 1
    end
    @test Observables.to_value(c) == 100

    # Observables.to_value still works on its own types
    obs2 = Observables.Observable("test")
    @test Observables.to_value(obs2) == "test"

    # Observables.to_value passes through plain values
    @test Observables.to_value(42) === 42
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

@testitem "distribute NamedTuple" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, (a=1, b="hello", c=3.0))
    d = MyObservables.distribute(s)

    @test d isa NamedTuple{(:a, :b, :c)}
    @test d.a isa Computed{Int}
    @test d.b isa Computed{String}
    @test d.c isa Computed{Float64}
    @test d.a[] == 1
    @test d.b[] == "hello"
    @test d.c[] == 3.0

    s[] = (a=10, b="world", c=5.0)
    @test d.a[] == 10
    @test d.b[] == "world"
    @test d.c[] == 5.0

    # from Computed source
    c = computed(rt) do; (x=s[].a * 2, y=s[].b) end
    dc = MyObservables.distribute(c)
    @test dc.x[] == 20
    @test dc.y[] == "world"
end

@testitem "distribute Tuple" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, (1, "hello", 3.0))
    d = MyObservables.distribute(s)

    @test d isa Tuple{Computed{Int}, Computed{String}, Computed{Float64}}
    @test d[1][] == 1
    @test d[2][] == "hello"
    @test d[3][] == 3.0

    s[] = (10, "world", 5.0)
    @test d[1][] == 10
    @test d[2][] == "world"
    @test d[3][] == 5.0

    # union types: element type changes within the union
    s2 = signal(rt, Tuple{Union{Nothing,Int}, Float64}, (nothing, 1.0))
    d2 = MyObservables.distribute(s2)
    @test d2[1] isa Computed{Union{Nothing,Int}}
    @test d2[1][] === nothing
    @test d2[2][] == 1.0

    s2[] = (42, 2.0)
    @test d2[1][] == 42
    @test d2[2][] == 2.0

    s2[] = (nothing, 3.0)
    @test d2[1][] === nothing
end

@testitem "distribute AbstractVector" begin
    using MyObservables
    using StaticArrays

    rt = Runtime()

    # plain Vector
    s = signal(rt, [1, 2, 3])
    d = MyObservables.distribute(s)
    @test d isa Vector{<:Computed}
    @test length(d) == 3
    @test d[1][] == 1
    @test d[2][] == 2
    @test d[3][] == 3

    s[] = [10, 20, 30]
    @test d[1][] == 10
    @test d[2][] == 20
    @test d[3][] == 30

    # SVector preserves type
    s2 = signal(rt, SVector(1, 2, 3))
    d2 = MyObservables.distribute(s2)
    @test d2 isa SVector{3, <:Computed}
    @test d2[1][] == 1
    @test d2[2][] == 2
    @test d2[3][] == 3

    s2[] = SVector(10, 20, 30)
    @test d2[1][] == 10
    @test d2[2][] == 20
    @test d2[3][] == 30
end
