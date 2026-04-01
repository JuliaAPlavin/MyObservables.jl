module AccessorsExt
using MyObservables, Accessors

function MyObservables.computed_bidi(f, source::MyObservables.AbstractNode{S}; skip_equal::Bool=false) where {S}
    T = Core.Compiler.return_type(f, Tuple{S})
    MyObservables.linked(source.runtime, T; skip_equal,
        set = v -> (source[] = Accessors.set(peek(source), f, v))) do
        f(source[])
    end
end

end
