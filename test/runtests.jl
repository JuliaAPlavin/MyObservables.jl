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

    # c should have no users and be unsubscribed (deps kept for reactivation)
    @test isempty(c.users)
    @test !isempty(c.deps)
    @test isempty(c.dep_versions)
end

@testitem "reactivation after unsubscribe" begin
    using MyObservables

    rt = Runtime()

    # Scenario 1: dispose effect, then read computed directly
    s = signal(rt, 1)
    c = computed(rt) do; s[] * 2; end
    e = effect!(rt) do; c[]; end
    @test c[] == 2
    dispose!(e)
    s[] = 100
    @test c[] == 200  # must not return stale value 2

    # Scenario 2: re-read from inside a new computed after unsubscribe
    rt2 = Runtime()
    s2 = signal(rt2, 1)
    c2 = computed(rt2) do; s2[] * 2; end
    e2 = effect!(rt2) do; c2[]; end
    dispose!(e2)
    s2[] = 50
    c2_wrapper = computed(rt2) do; c2[] + 1; end
    @test c2_wrapper[] == 101  # must not return stale 2+1=3

    # Scenario 3: chain still propagates after reactivation
    s2[] = 10
    @test c2_wrapper[] == 21  # c2=20, wrapper=21

    # Scenario 4: conditional dep triggers unsubscribe, then re-read
    rt3 = Runtime()
    flag = signal(rt3, true)
    s3 = signal(rt3, 1)
    inner = computed(rt3) do; s3[] * 2; end
    outer = computed(rt3) do; flag[] ? inner[] : 999; end
    e3 = effect!(rt3) do; outer[]; end

    @test outer[] == 2
    flag[] = false        # inner loses its last user → unsubscribe
    @test outer[] == 999
    s3[] = 100            # inner doesn't get notified
    flag[] = true         # outer reads inner again
    @test outer[] == 200  # must re-execute inner, not return stale 2
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

@testitem "error in computed doesn't permanently block effects" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 1)
    fail = Ref(false)

    c = computed(rt) do
        fail[] && error("boom")
        s[] * 10
    end

    log = Int[]
    e = effect!(rt) do
        push!(log, c[])
    end
    @test log == [10]

    # Trigger error in c during flush
    fail[] = true
    @test_throws ErrorException s[] = 2

    # Fix the function and change signal — effect must recover
    fail[] = false
    s[] = 3
    @test log == [10, 30]
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

@testitem "effect error doesn't orphan sibling effects" begin
    using MyObservables

    rt = Runtime()
    s = signal(rt, 0)
    other = signal(rt, 0)

    log = Int[]
    e_good = effect!(rt) do
        push!(log, s[])
    end
    e_bad = effect!(rt) do
        v = s[]
        v > 0 && error("boom")
    end

    @test log == [0]

    # e_bad will throw during flush; e_good must not be orphaned
    @test_throws ErrorException s[] = 1

    # Regardless of which effect ran first:
    # - if e_good ran before e_bad: log already has 1
    # - if e_bad ran first: e_good is still pending
    # An unrelated signal change triggers flush, processing any remaining effects
    other[] = 99
    @test log == [0, 1]
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

@testitem "sweep" begin
    using MyObservables
    using MyObservables: sweep

    # basic sweep with do-block
    rt = Runtime()
    x = signal(rt, 0)
    y = computed(rt) do
        x[] * 2
    end
    @test sweep(x, 1:5) do; y[]; end == [2, 4, 6, 8, 10]

    # direct form
    @test sweep(x, 1:5, y) == [2, 4, 6, 8, 10]

    # signal restored after sweep
    @test x[] == 0
    @test y[] == 0

    # effects not triggered during sweep
    effect_log = Int[]
    e = effect!(rt) do
        push!(effect_log, x[])
    end
    @test effect_log == [0]
    sweep(x, [10, 20, 30], y)
    @test effect_log == [0]  # effect did not fire

    # effects still work normally after sweep
    x[] = 5
    @test effect_log == [0, 5]
    @test y[] == 10

    # deep chain
    rt2 = Runtime()
    a = signal(rt2, 1)
    b = computed(rt2) do; a[] + 1; end
    c = computed(rt2) do; b[] * 3; end
    d = computed(rt2) do; c[] - 2; end
    @test sweep(a, [1, 2, 3], d) == [4, 7, 10]
    @test a[] == 1

    # only target chain recomputed, not other branches
    rt3 = Runtime()
    s = signal(rt3, 1)
    target_count = Ref(0)
    target = computed(rt3) do
        target_count[] += 1
        s[] * 10
    end
    other_count = Ref(0)
    other = computed(rt3) do
        other_count[] += 1
        s[] + 100
    end
    # pull both to establish deps
    @test target[] == 10
    @test other[] == 101
    @test target_count[] == 1
    @test other_count[] == 1

    @test sweep(s, 1:3, target) == [10, 20, 30]
    @test target_count[] == 4  # recomputed 3 times during sweep
    @test other_count[] == 1   # never recomputed

    # diamond graph
    rt4 = Runtime()
    root = signal(rt4, 2)
    left = computed(rt4) do; root[] + 1; end
    right = computed(rt4) do; root[] * 2; end
    bottom = computed(rt4) do; left[] + right[]; end
    @test sweep(root, [1, 2, 3], bottom) == [4, 7, 10]
    @test root[] == 2

    # mixed deps: target depends on swept signal AND another signal
    rt5 = Runtime()
    p = signal(rt5, 10)
    q = signal(rt5, 100)
    mix = computed(rt5) do; p[] + q[]; end
    @test sweep(p, [1, 2, 3], mix) == [101, 102, 103]
    @test p[] == 10
    @test q[] == 100

    # error in f — signal still restored
    rt6 = Runtime()
    s6 = signal(rt6, 0)
    @test_throws ErrorException sweep(s6, [1, 2, 3]) do
        s6[] == 2 && error("boom")
        s6[]
    end
    @test s6[] == 0  # restored despite error

    # skip_equal computed in chain
    rt7 = Runtime()
    s7 = signal(rt7, 1)
    clamped = computed(rt7; skip_equal=true) do
        clamp(s7[], 0, 5)
    end
    downstream = computed(rt7) do
        clamped[] * 10
    end
    @test sweep(s7, [3, 7, -1, 4], downstream) == [30, 50, 0, 40]
    @test s7[] == 1

    # sweep inside computed: trajectory depends only on explicitly read deps
    rt8 = Runtime()
    x8 = signal(rt8, 10)
    y8 = signal(rt8, 0)
    z8 = computed(rt8) do; x8[] + y8[]; end

    trajectory = computed(rt8) do
        x8[]  # explicitly track x
        sweep(y8, [1, 2, 3], z8)
    end
    @test trajectory[] == [11, 12, 13]

    traj_ver = trajectory.version
    x8[] = 20
    @test trajectory[] == [21, 22, 23]
    @test trajectory.version > traj_ver  # recomputed (depends on x)

    # y change does NOT trigger recompute (sweep doesn't track)
    traj_ver = trajectory.version
    y8[] = 99
    @test trajectory.version == traj_ver  # not recomputed
    @test trajectory[] == [21, 22, 23]
end

@testitem "linked basics" begin
    using MyObservables
    using MyObservables: linked

    rt = Runtime()
    a = signal(rt, 1)
    b = signal(rt, 2)

    # Forward: works like computed (lazy, tracked)
    c = linked(rt; set = v -> (a[] = v[1]; b[] = v[2])) do
        (a[], b[])
    end
    @test c[] == (1, 2)

    # Forward: upstream change updates linked node
    a[] = 10
    @test c[] == (10, 2)

    # Backward: setting linked node propagates to sources
    c[] = (100, 200)
    @test a[] == 100
    @test b[] == 200
    @test c[] == (100, 200)

    # Effects fire after backward set
    log = Tuple{Int,Int}[]
    e = effect!(rt) do
        push!(log, c[])
    end
    @test log == [(100, 200)]

    c[] = (3, 4)
    @test log == [(100, 200), (3, 4)]
    @test a[] == 3
    @test b[] == 4

    # Forward still works after backward
    a[] = 50
    @test log == [(100, 200), (3, 4), (50, 4)]
end

@testitem "linked caching" begin
    using MyObservables
    using MyObservables: linked

    rt = Runtime()
    s = signal(rt, 1)
    call_count = Ref(0)
    l = linked(rt; set = v -> (s[] = v)) do
        call_count[] += 1
        s[] * 10
    end

    e = effect!(rt) do
        l[]
        l[]  # read twice
    end
    @test call_count[] == 1  # computed only once

    s[] = 2
    @test call_count[] == 2  # recomputed once
end

@testitem "linked batching" begin
    using MyObservables
    using MyObservables: linked

    rt = Runtime()
    a = signal(rt, 1)
    b = signal(rt, 2)

    c = linked(rt; set = v -> (a[] = v[1]; b[] = v[2])) do
        (a[], b[])
    end

    # Effect sees only the final state, not intermediate (10, 2)
    log = Tuple{Int,Int}[]
    e = effect!(rt) do
        push!(log, c[])
    end
    @test log == [(1, 2)]

    c[] = (10, 20)
    @test log == [(1, 2), (10, 20)]  # one update, not two

    # Backward set inside existing batch
    batch(rt) do
        c[] = (30, 40)
        a[] = 50  # extra mutation in same batch
    end
    @test log == [(1, 2), (10, 20), (50, 40)]  # one flush at end
end

@testitem "linked re-entrancy detection" begin
    using MyObservables
    using MyObservables: linked

    rt = Runtime()
    s = signal(rt, 1)

    # Self-referential setter
    local l
    l = linked(rt; set = v -> (l[] = v + 1)) do
        s[]
    end
    l[]  # establish deps
    @test_throws ErrorException l[] = 10
end

@testitem "linked error recovery" begin
    using MyObservables
    using MyObservables: linked

    rt = Runtime()
    a = signal(rt, 1)
    b = signal(rt, 2)

    c = linked(rt; set = v -> begin
        a[] = v[1]
        error("boom")
        b[] = v[2]
    end) do
        (a[], b[])
    end

    log = Tuple{Int,Int}[]
    e = effect!(rt) do
        push!(log, c[])
    end
    @test log == [(1, 2)]

    @test_throws ErrorException c[] = (10, 20)
    # a was set before error, b was not
    @test a[] == 10
    @test b[] == 2
    # node is in consistent state (dirty from a's update), can still be read
    @test c[] == (10, 2)
end

@testitem "linked chained" begin
    using MyObservables
    using MyObservables: linked

    rt = Runtime()
    a = signal(rt, 1)
    b = signal(rt, 2)

    # C aggregates a and b
    c = linked(rt; set = v -> (a[] = v[1]; b[] = v[2])) do
        (a[], b[])
    end

    # D transforms C
    d = linked(rt; set = v -> (c[] = (v, v))) do
        c[][1] + c[][2]
    end

    @test d[] == 3
    d[] = 10  # → c[] = (10, 10) → a = 10, b = 10
    @test a[] == 10
    @test b[] == 10
    @test c[] == (10, 10)
    @test d[] == 20
end

@testitem "linked no spurious dep tracking" begin
    using MyObservables
    using MyObservables: linked

    rt = Runtime()
    a = signal(rt, 1)
    b = signal(rt, 10)

    # Setter reads b to compute what to set a
    c = linked(rt; set = v -> (a[] = v - peek(b))) do
        a[] + b[]
    end

    log = Int[]
    e = effect!(rt) do
        push!(log, c[])
    end
    @test log == [11]

    # Set c from within an effect-like context should not
    # register b as a dependency of anything unexpected
    c[] = 15  # a[] = 15 - 10 = 5
    @test a[] == 5
    @test c[] == 15
end

@testitem "linked read-A-write-B" begin
    using MyObservables
    using MyObservables: linked

    rt = Runtime()
    source = signal(rt, 10)
    target = signal(rt, 0)

    junction = linked(rt; set = v -> (target[] = v)) do
        source[]
    end

    @test junction[] == 10
    junction[] = 42
    @test target[] == 42
    @test source[] == 10  # untouched

    # Forward still works
    source[] = 20
    @test junction[] == 20
end

@testitem "linked with sweep" begin
    using MyObservables
    using MyObservables: linked, sweep

    rt = Runtime()
    a = signal(rt, 1)
    b = signal(rt, 2)

    c = linked(rt; set = v -> (a[] = v[1]; b[] = v[2])) do
        (a[], b[])
    end

    # sweep over source signal — linked node recomputes via forward
    @test sweep(a, [10, 20, 30], c) == [(10, 2), (20, 2), (30, 2)]
    @test a[] == 1  # restored
end

@testitem "computed_bidi" begin
    using MyObservables
    using MyObservables: computed_bidi
    using Accessors

    rt = Runtime()

    # Property optic
    state = signal(rt, (x=1, y=2, z=3))
    vx = computed_bidi(@optic(_.x), state)
    @test vx[] == 1

    state[] = (x=10, y=2, z=3)
    @test vx[] == 10

    # Backward: set vx updates state
    vx[] = 42
    @test state[] == (x=42, y=2, z=3)
    @test vx[] == 42

    # Composed optic
    nested = signal(rt, (user=(name="Alice", age=30), theme="dark"))
    name_view = computed_bidi(@optic(_.user.name), nested)
    @test name_view[] == "Alice"

    name_view[] = "Bob"
    @test nested[] == (user=(name="Bob", age=30), theme="dark")

    # Effects fire
    log = String[]
    e = effect!(rt) do
        push!(log, name_view[])
    end
    @test log == ["Bob"]
    name_view[] = "Charlie"
    @test log == ["Bob", "Charlie"]
    @test nested[].user.name == "Charlie"

    # Index optic on tuple
    t = signal(rt, (10, 20, 30))
    v2 = computed_bidi(@optic(_[2]), t)
    @test v2[] == 20
    v2[] = 99
    @test t[] == (10, 99, 30)

    # Round-trip consistency
    s = signal(rt, (a=1, b=2))
    va = computed_bidi(@optic(_.a), s)
    va[] = 100
    @test va[] == 100  # GetPut law
    old_s = s[]
    va[] = va[]  # PutGet: setting current value is no-op (conceptually)
    @test s[] == old_s
end

@testitem "changes" begin
    using MyObservables: Runtime, signal, computed, effect!, changes

    rt = Runtime()
    s = signal(rt, 1)
    c = computed(rt) do
        s[] > 0 ? [1, 2] : [0]
    end
    d = changes(c)

    log = []
    effect!(rt) do
        push!(log, d[])
    end
    @test log == [[1, 2]]

    # same value (new array, but isequal) → no propagation
    s[] = 2
    @test log == [[1, 2]]

    # different value → propagates
    s[] = -1
    @test log == [[1, 2], [0]]

    # same again
    s[] = -5
    @test log == [[1, 2], [0]]
end

@testitem "debounce" begin
    using MyObservables

    DT = 0.05

    # initial value
    rt = Runtime()
    s = signal(rt, 10)
    d = debounce(s, DT)
    @test d.signal[] == 10

    # basic: set source, wait, check output
    s[] = 20
    @test d.signal[] == 10  # not yet updated
    sleep(DT + 0.05)
    @test d.signal[] == 20

    # rapid changes: only final value emitted
    s[] = 1
    s[] = 2
    s[] = 3
    @test d.signal[] == 20  # still old, timer keeps resetting
    sleep(DT + 0.05)
    @test d.signal[] == 3  # final value

    # timer reset: change, wait less than dt, change again
    s[] = 100
    sleep(DT / 2)
    s[] = 200
    sleep(DT / 2)
    @test d.signal[] == 3  # timer was reset, not fired yet
    sleep(DT)
    @test d.signal[] == 200

    # dispose stops updates
    dispose!(d.effect)
    s[] = 999
    sleep(DT + 0.05)
    @test d.signal[] == 200  # no update after dispose

    # works with downstream effects
    rt2 = Runtime()
    s2 = signal(rt2, 0)
    d2 = debounce(s2, DT)
    log = Int[]
    effect!(rt2) do
        push!(log, d2.signal[])
    end
    @test log == [0]
    s2[] = 42
    @test log == [0]  # not yet
    sleep(DT + 0.05)
    @test log == [0, 42]

    # Signal{Any} with type change
    rt3 = Runtime()
    s3 = signal(rt3, Any, 1)
    d3 = debounce(s3, DT)
    @test d3.signal[] === 1
    s3[] = 2.5
    sleep(DT + 0.05)
    @test d3.signal[] === 2.5
    s3[] = "hello"
    sleep(DT + 0.05)
    @test d3.signal[] === "hello"
end

@testitem "throttle" begin
    using MyObservables

    DT = 0.05

    # initial value
    rt = Runtime()
    s = signal(rt, 10)
    t = throttle(s, DT)
    @test t.signal[] == 10

    # creation starts a cooldown; first change is suppressed (trailing edge)
    s[] = 20
    @test t.signal[] == 10  # in cooldown from creation
    sleep(DT + 0.05)
    @test t.signal[] == 20  # trailing edge

    # after cooldown expires, next change is immediate (leading edge)
    sleep(DT + 0.05)  # ensure back to IDLE
    s[] = 30
    @test t.signal[] == 30  # leading edge: immediate

    # further changes during cooldown are suppressed
    s[] = 40
    @test t.signal[] == 30  # suppressed
    s[] = 50
    @test t.signal[] == 30  # still suppressed

    # trailing edge emits last value
    sleep(DT + 0.05)
    @test t.signal[] == 50

    # dispose stops updates
    sleep(DT + 0.05)
    dispose!(t.effect)
    s[] = 999
    sleep(DT + 0.05)
    @test t.signal[] == 50  # no update after dispose

    # works with downstream effects
    rt2 = Runtime()
    s2 = signal(rt2, 0)
    t2 = throttle(s2, DT)
    log = Int[]
    effect!(rt2) do
        push!(log, t2.signal[])
    end
    @test log == [0]
    # creation cooldown; changes are suppressed then trailing fires
    s2[] = 1
    s2[] = 2
    @test log == [0]  # suppressed during cooldown
    sleep(DT + 0.05)
    @test log == [0, 2]  # trailing edge
    # back to IDLE, leading edge works
    sleep(DT + 0.05)
    s2[] = 5
    @test log == [0, 2, 5]  # immediate

    # Signal{Any} with type change
    rt3 = Runtime()
    s3 = signal(rt3, Any, 1)
    t3 = throttle(s3, DT)
    @test t3.signal[] === 1
    sleep(DT + 0.05)  # wait for creation cooldown
    s3[] = 2.5
    @test t3.signal[] === 2.5  # leading edge
    sleep(DT + 0.05)
    s3[] = "hello"
    @test t3.signal[] === "hello"  # leading edge
end
