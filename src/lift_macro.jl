const _GLOBAL_RT = Ref(Runtime())

Observable(val) = signal(_GLOBAL_RT[], val)


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

macro lift(exp)
    nodes = collect(find_dollar_nodes(exp))
    isempty(nodes) && error("No interpolated observables found. Use \$(obs) syntax.")
    sym_map = Dict(n => gensym("node") for n in nodes)
    replace_dollars!(exp, sym_map)
    syms = [sym_map[n] for n in nodes]
    let_bindings = [:($(esc(s)) = $_ensure_node($(esc(n)))) for (n, s) in zip(nodes, syms)]
    quote
        let $(let_bindings...)
            $computed($runtime($(esc.(syms)...))) do
                $(esc(exp))
            end
        end
    end
end
