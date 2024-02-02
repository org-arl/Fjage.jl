using Base: isexpr

macro kwdef(expr)
    expr = macroexpand(__module__, expr) # to expand @static
    isexpr(expr, :struct) || error("Invalid usage of @kwdef")
    T = expr.args[2]
    if T isa Expr && T.head === :<:
        T = T.args[1]
    end

    params_ex = Expr(:parameters)
    call_args = Any[]

    _kwdef!(expr.args[3], params_ex.args, call_args)
    # Only define a constructor if the type has fields, otherwise we'll get a stack
    # overflow on construction
    if !isempty(params_ex.args)
        T_no_esc,_ = strip_esc(T)
        if T_no_esc isa Symbol
            sig = :(($(esc(T)))($params_ex))
            call = :(($(esc(T)))($(call_args...)))
            body = Expr(:block, __source__, call)
            kwdefs = Expr(:function, sig, body)
        elseif isexpr(T_no_esc, :curly)
            # if T == S{A<:AA,B<:BB}, define two methods
            #   S(...) = ...
            #   S{A,B}(...) where {A<:AA,B<:BB} = ...
            S = T.args[1]
            P = T.args[2:end]
            Q = Any[isexpr(U, :<:) ? U.args[1] : U for U in P]
            SQ = :($S{$(Q...)})
            body1 = Expr(:block, __source__, :(($(esc(S)))($(call_args...))))
            sig1 = :(($(esc(S)))($params_ex))
            def1 = Expr(:function, sig1, body1)
            body2 = Expr(:block, __source__, :(($(esc(SQ)))($(call_args...))))
            sig2 = :(($(esc(SQ)))($params_ex) where {$(esc.(P)...)})
            def2 = Expr(:function, sig2, body2)
            kwdefs = Expr(:block, def1, def2)
        else
            @show T_no_esc
            error("Invalid usage of @kwdef")
        end
    else
        kwdefs = nothing
    end
    return quote
        $(esc(:($Base.@__doc__ $expr)))
        $kwdefs
    end
end

# @kwdef helper function
# mutates arguments inplace
function _kwdef!(blk, params_args, call_args, esc_count = 0)
    for i in eachindex(blk.args)
        ei = blk.args[i]
        if ei isa Symbol
            #  var
            push!(params_args, ei)
            push!(call_args, ei)
        elseif ei isa Expr
            is_atomic = ei.head === :atomic
            ei = is_atomic ? first(ei.args) : ei # strip "@atomic" and add it back later
            is_const = ei.head === :const
            ei = is_const ? first(ei.args) : ei # strip "const" and add it back later
            # Note: `@atomic const ..` isn't valid, but reconstruct it anyway to serve a nice error
            if ei isa Symbol
                # const var
                push!(params_args, ei)
                push!(call_args, ei)
            elseif ei.head === :(=)
                lhs = ei.args[1]
                lhs_no_esc, lhs_esc_count = strip_esc(lhs)
                if lhs_no_esc isa Symbol
                    #  var = defexpr
                    var = lhs_no_esc
                elseif lhs_no_esc isa Expr && lhs_no_esc.head === :(::) && strip_esc(lhs_no_esc.args[1])[1] isa Symbol
                    #  var::T = defexpr
                    var = strip_esc(lhs_no_esc.args[1])[1]
                else
                    # something else, e.g. inline inner constructor
                    #   F(...) = ...
                    continue
                end
                defexpr = ei.args[2]  # defexpr
                defexpr = wrap_esc(defexpr, esc_count + lhs_esc_count)
                push!(params_args, Expr(:kw, var, esc(defexpr)))
                push!(call_args, var)
                lhs = is_const ? Expr(:const, lhs) : lhs
                lhs = is_atomic ? Expr(:atomic, lhs) : lhs
                blk.args[i] = lhs # overrides arg
            elseif ei.head === :(::) && strip_esc(ei.args[1])[1] isa Symbol
                # var::Typ
                var,_ = strip_esc(ei.args[1])
                push!(params_args, var)
                push!(call_args, var)
            elseif ei.head === :block
                # can arise with use of @static inside type decl
                _kwdef!(ei, params_args, call_args)
            elseif ei.head === :escape
                _kwdef!(ei, params_args, call_args, esc_count + 1)
            end
        end
    end
    blk
end

function strip_esc(expr)
    count = 0
    while isexpr(expr, :escape)
        expr = expr.args[1]
        count += 1
    end
    return (expr, count)
end

function wrap_esc(expr, count)
    for _ = 1:count
        expr = esc(expr)
    end
    return expr
end