"""
    debounce(source::AbstractNode{T}, dt::Real) -> (; signal::Signal{T}, effect::EffectNode)

Wait for `dt` seconds of silence (no changes to `source`), then emit the latest value.
Returns a named tuple with the output `signal` and the internal `effect`.
Dispose the effect to stop: `dispose!(result.effect)`.
"""
function debounce(source::AbstractNode{T}, dt::Real) where T
    rt = runtime(source)
    out = signal(rt, T, peek(source))
    timer_ref = Ref{Union{Nothing,Timer}}(nothing)

    eff = effect!(rt) do
        source[]  # track source
        t = timer_ref[]
        t !== nothing && close(t)
        timer_ref[] = Timer(dt) do _
            eff.disposed && return
            out[] = peek(source)
        end
    end

    return (; signal=out, effect=eff)
end

"""
    throttle(source::AbstractNode{T}, dt::Real) -> (; signal::Signal{T}, effect::EffectNode)

Emit immediately on first change (leading edge), then at most once per `dt` seconds.
Always emits the trailing value when the cooldown window closes.
Returns a named tuple with the output `signal` and the internal `effect`.
Dispose the effect to stop: `dispose!(result.effect)`.
"""
function throttle(source::AbstractNode{T}, dt::Real) where T
    rt = runtime(source)
    out = signal(rt, T, peek(source))
    timer_ref = Ref{Union{Nothing,Timer}}(nothing)
    has_pending = Ref(false)

    function emit_and_cooldown!(v)
        out[] = v
        has_pending[] = false
        timer_ref[] = Timer(dt) do _
            eff.disposed && return
            # invokelatest needed: Timer task world age may predate downstream effect closures
            if has_pending[]
                Base.invokelatest(emit_and_cooldown!, peek(source))
            else
                timer_ref[] = nothing
            end
        end
    end

    eff = effect!(rt) do
        v = source[]
        if timer_ref[] === nothing
            emit_and_cooldown!(v)
        else
            has_pending[] = true
        end
    end

    return (; signal=out, effect=eff)
end
