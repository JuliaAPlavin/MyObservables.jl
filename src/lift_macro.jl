const _GLOBAL_RT = Ref(Runtime())

Observable(val) = signal(_GLOBAL_RT[], val)


find_dollar_nodes(x) = Set{Any}()
function find_dollar_nodes(e::Expr)
    if e.head == :$ && length(e.args) == 1
        return Set{Any}([e.args[1]])
    end
    mapreduce(find_dollar_nodes, union!, e.args; init=Set{Any}())
end

function replace_dollars!(e::Expr)
    for (i, arg) in enumerate(e.args)
        if arg isa Expr && arg.head == :$ && length(arg.args) == 1
            e.args[i] = Expr(:ref, arg.args[1])
        elseif arg isa Expr
            replace_dollars!(arg)
        end
    end
    e
end

macro lift(exp)
    nodes = find_dollar_nodes(exp)
    isempty(nodes) && error("No interpolated observables found. Use \$(obs) syntax.")
    replace_dollars!(exp)
    quote
        computed(runtime($(esc.(nodes)...))) do
            $(esc(exp))
        end
    end
end
