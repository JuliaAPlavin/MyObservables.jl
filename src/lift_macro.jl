const _GLOBAL_RT = Ref(Runtime())

Observable(val) = signal(_GLOBAL_RT[], val)


expand_fstrings(x, mod) = x
function expand_fstrings(e::Expr, mod)
    if Base.isexpr(e, :macrocall) && length(e.args) >= 1 && e.args[1] == Symbol("@f_str")
        return macroexpand(mod, e; recursive=true)
    end
    Expr(e.head, map(a -> expand_fstrings(a, mod), e.args)...)
end


find_dollar_nodes(x) = Set{Any}()
function find_dollar_nodes(e::Expr)
    if e.head == :$ && length(e.args) == 1
        return Set{Any}([e.args[1]])
    end
    mapreduce(find_dollar_nodes, union!, e.args; init=Set{Any}())
end

function replace_dollars!(e::Expr, sym_map)
    for (i, arg) in enumerate(e.args)
        if arg isa Expr && arg.head == :$ && length(arg.args) == 1
            e.args[i] = Expr(:ref, sym_map[arg.args[1]])
        elseif arg isa Expr
            replace_dollars!(arg, sym_map)
        end
    end
    e
end

function lift(f, args...; kwargs...)
    processed = map(_maybe_node, args)
    nodes = filter(n -> n isa AbstractNode, processed)
    rt = isempty(nodes) ? _GLOBAL_RT[] : runtime(nodes...)
    computed(rt; kwargs...) do
        f(map(to_value, processed)...)
    end
end

function lift(::Type{T}, f, args...; kwargs...) where {T}
    processed = map(_maybe_node, args)
    nodes = filter(n -> n isa AbstractNode, processed)
    rt = isempty(nodes) ? _GLOBAL_RT[] : runtime(nodes...)
    computed(rt, T; kwargs...) do
        f(map(to_value, processed)...)
    end
end

macro lift(exp)
    exp = expand_fstrings(exp, __module__)

    # Extract optional type annotation: @lift (expr)::T
    result_type = nothing
    if Base.isexpr(exp, :(::)) && length(exp.args) == 2
        result_type = exp.args[2]
        exp = exp.args[1]
    end

    nodes = collect(find_dollar_nodes(exp))
    isempty(nodes) && error("No interpolated observables found. Use \$(obs) syntax.")
    sym_map = Dict(n => gensym("node") for n in nodes)
    replace_dollars!(exp, sym_map)
    syms = [sym_map[n] for n in nodes]
    let_bindings = [:($(esc(s)) = $_ensure_node($(esc(n)))) for (n, s) in zip(nodes, syms)]
    rt_expr = :($runtime($(esc.(syms)...)))
    computed_call = if result_type !== nothing
        :($computed($rt_expr, $(esc(result_type))) do
            $(esc(exp))
        end)
    else
        :($computed($rt_expr) do
            $(esc(exp))
        end)
    end
    quote
        let $(let_bindings...)
            $computed_call
        end
    end
end
