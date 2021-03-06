# reduce() versions
@inline function reduce{FSA <: Union{FixedArray, Tuple}}(f, a::FSA)
    length(a) == 1 && return a[1]
    @inbounds begin
        red = f(a[1], a[2])
        for i=3:length(a)
            red = f(red, a[i])
        end
    end
    red
end

@inline function reduce(f::Functor{2}, a::Mat)
    length(a) == 1 && return a[1,1]
    @inbounds begin
        red = reduce(f, Tuple(a)[1])
        for i=2:size(a, 2)
            red = f(red, reduce(f, Tuple(a)[i]))
        end
    end
    red
end


#------------------------------------------------------------------------------
# map() machinery

# Get an expression indexing the collection `name` of type `T` for use in map()
index_expr{T <: Number}(::Type{T},     name, inds::Int...)    = :($name)
index_expr{T <: FixedArray}(::Type{T}, name, inds::Int...)    = :($name[$(inds...)])
index_expr{T <: AbstractArray}(::Type{T}, name, inds::Int...) = :($name[$(inds...)])

# Get expression checking size of collection `name` against `SIZE`
function sizecheck_expr{T <: Number}(::Type{T}, name, SIZE)
    :nothing
end
function sizecheck_expr{FSA<:FixedArray}(::Type{FSA}, name, SIZE)
    if size(FSA) == SIZE
        :nothing
    else
        :(throw(DimensionMismatch(string($FSA)*" is wrong size")))
    end
end
function sizecheck_expr{A<:AbstractArray}(::Type{A}, name, SIZE)
    quote
        # Note - should be marked with @boundscheck in 0.5
        size($name) == $SIZE || throw(DimensionMismatch(string($A)*" is wrong size"))
    end
end

# Type wrapper to signify that a similar FSA should be constructed as the map()
# output type via construct_similar()
immutable SimilarTo{FSA}; end

# Get expression to construct FSA from a nested tuple of storage generated by map()
constructor_expr{FSA <: FixedArray}(::Type{FSA}, tuple_expr::Expr) = :($FSA($tuple_expr))
constructor_expr{FSA <: FixedVectorNoTuple}(::Type{FSA}, tuple_expr::Expr) = :($FSA($tuple_expr...))
constructor_expr{FSA <: FixedArray}(::Type{SimilarTo{FSA}}, tuple_expr::Expr) = :(construct_similar($FSA, $tuple_expr))

# Generate an unrolled nested tuple of calls mapping funcname across the input,
# constructing an `OutFSA` to store the result.
#
# julia> FixedSizeArrays.unrolled_map_expr(:f, Vec{2,Bool}, (2,), (Vec{2,Int},Int), (:A,:b))
#
# generates, after cleaning up:
#
#    (FixedSizeArrays.Vec{2,Bool})(
#        tuple(tuple(f(A[1,1],b), f(A[2,1],b)),
#              tuple(f(A[1,2],b), f(A[2,2],b)))
#    )
function unrolled_map_expr(funcname, OutFSA, SIZE, argtypes, argnames)
    sizecheck = [sizecheck_expr(T,n,SIZE) for (T,n) in zip(argtypes,argnames)]
    tuple_expr = fill_tuples_expr(SIZE) do inds...
        Expr(:call, funcname,
            [index_expr(argtypes[i], argnames[i], inds...) for i=1:length(argtypes)]...
        )
    end
    quote
        $(Expr(:meta, :inline))
        $(sizecheck...)
        @inbounds rvalue = $(constructor_expr(OutFSA, tuple_expr))
        rvalue
    end
end


# map() comes in two flavours:
#
# 1) You can specify the output type with the first argument
#   map(func, ::Type{OutFSA}, arg1, arg2, ...)

# General N-ary version with explicit output.  (Unary and binary versions are
# written out below since this generates better code in julia-0.4.)
@generated function map{OutFSA<:FixedArray}(func, ::Type{OutFSA}, args...)
    argexprs = ntuple(i->:(args[$i]), length(args))
    unrolled_map_expr(:func, OutFSA, size(OutFSA), args, argexprs)
end
# Binary
@generated function map{OutFSA<:FixedArray}(func, ::Type{OutFSA}, arg1, arg2)
    unrolled_map_expr(:func, OutFSA, size(OutFSA), (arg1,arg2), (:arg1,:arg2))
end
# Unary
@generated function map{OutFSA<:FixedArray}(func, ::Type{OutFSA}, arg1)
    unrolled_map_expr(:func, OutFSA, size(OutFSA), (arg1,), (:arg1,))
end


# 2) You can let map() infer the output FixedArray type from `func`
#   map(func, fixed_arrays...)

# Binary, inferred output
@generated function map{F1<:FixedArray, F2<:FixedArray}(func, arg1::F1, arg2::F2)
    unrolled_map_expr(:func, SimilarTo{arg1}, size(F1), (arg1,arg2), (:arg1,:arg2))
end
@generated function map{F<:FixedArray}(func, arg1::F, arg2::Union{Number,AbstractArray})
    unrolled_map_expr(:func, SimilarTo{arg1}, size(F), (arg1,arg2), (:arg1,:arg2))
end
@generated function map{F<:FixedArray}(func, arg1::Union{Number,AbstractArray}, arg2::F)
    unrolled_map_expr(:func, SimilarTo{arg2}, size(F), (arg1,arg2), (:arg1,:arg2))
end
# Unary, inferred output
@generated function map{F<:FixedArray}(func, arg1::F)
    unrolled_map_expr(:func, SimilarTo{arg1}, size(F), (arg1,), (:arg1,))
end


# Nullary special case version.
#
# TODO: This is inconsistent, since it maps *indices* through the functor
# rather than using a functor with no arguments.
@generated function map{FSA <: FixedArray}(F, ::Type{FSA})
    tuple_expr = fill_tuples_expr((inds...) -> :(F($(inds...))), size(FSA))
    constructor_expr(FSA, tuple_expr)
end

@inline map{T}(::Type{T}, v::FixedArray{T}) = v
