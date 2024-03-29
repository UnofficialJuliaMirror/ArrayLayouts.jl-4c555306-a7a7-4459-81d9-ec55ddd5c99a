### This support BLAS style multiplication
#           α * A * B + β C
# but avoids the broadcast machinery

# Lazy representation of α*A*B + β*C
struct MulAdd{StyleA, StyleB, StyleC, T, AA, BB, CC}
    α::T
    A::AA
    B::BB
    β::T
    C::CC
end

@inline MulAdd{StyleA,StyleB,StyleC}(α::T, A::AA, B::BB, β::T, C::CC) where {StyleA,StyleB,StyleC,T,AA,BB,CC} =
    MulAdd{StyleA,StyleB,StyleC,T,AA,BB,CC}(α,A,B,β,C)

@inline function MulAdd{StyleA,StyleB,StyleC}(αT, A, B, βV, C) where {StyleA,StyleB,StyleC}
    α,β = promote(αT,βV)
    MulAdd{StyleA,StyleB,StyleC}(α, A, B, β, C)
end

@inline MulAdd(α, A::AA, B::BB, β, C::CC) where {AA,BB,CC} = 
    MulAdd{typeof(MemoryLayout(AA)), typeof(MemoryLayout(BB)), typeof(MemoryLayout(CC))}(α, A, B, β, C)

@inline _mul_eltype(A) = A
@inline _mul_eltype(A, B) = Base.promote_op(*, A, B)
@inline _mul_eltype(A, B, C, D...) = _mul_eltype(Base.promote_op(*, A, B), C, D...)

@inline eltype(::MulAdd{StyleA,StyleB,StyleC,T,AA,BB,CC}) where {StyleA,StyleB,StyleC,T,AA,BB,CC} =
     promote_type(_mul_eltype(T, eltype(AA), eltype(BB)), _mul_eltype(T, eltype(CC)))

size(M::MulAdd, p::Int) = size(M)[p]
axes(M::MulAdd, p::Int) = axes(M)[p]
length(M::MulAdd) = prod(size(M))
size(M::MulAdd) = map(length,axes(M))
axes(M::MulAdd) = axes(M.C)

similar(M::MulAdd, ::Type{T}, axes) where {T,N} = similar(Array{T}, axes)
similar(M::MulAdd, ::Type{T}) where T = similar(M, T, axes(M))
similar(M::MulAdd) = similar(M, eltype(M))

check_mul_axes(A) = nothing
_check_mul_axes(::Number, ::Number) = nothing
_check_mul_axes(::Number, _) = nothing
_check_mul_axes(_, ::Number) = nothing
_check_mul_axes(A, B) = axes(A,2) == axes(B,1) || throw(DimensionMismatch("Second axis of A, $(axes(A,2)), and first axis of B, $(axes(B,1)) must match"))
function check_mul_axes(A, B, C...) 
    _check_mul_axes(A, B)
    check_mul_axes(B, C...)
end

# we need to special case AbstractQ as it allows non-compatiple multiplication
function check_mul_axes(A::AbstractQ, B, C...) 
    axes(A.factors, 1) == axes(B, 1) || axes(A.factors, 2) == axes(B, 1) ||  
        throw(DimensionMismatch("First axis of B, $(axes(B,1)) must match either axes of A, $(axes(A))"))
    check_mul_axes(B, C...)
end


function instantiate(M::MulAdd)
    @boundscheck check_mul_axes(M.α, M.A, M.B)
    @boundscheck check_mul_axes(M.β, M.C)
    @boundscheck axes(M.A,1) == axes(M.C,1) || throw(DimensionMismatch("First axis of A, $(axes(M.A,1)), and first axis of C, $(axes(M.C,1)) must match"))
    @boundscheck axes(M.B,2) == axes(M.C,2) || throw(DimensionMismatch("Second axis of B, $(axes(M.B,2)), and second axis of C, $(axes(M.C,2)) must match"))
    M
end

const ArrayMulArrayAdd{StyleA,StyleB,StyleC} = MulAdd{StyleA,StyleB,StyleC,<:Any,<:AbstractArray,<:AbstractArray,<:AbstractArray}
const MatMulVecAdd{StyleA,StyleB,StyleC} = MulAdd{StyleA,StyleB,StyleC,<:Any,<:AbstractMatrix,<:AbstractVector,<:AbstractVector}
const MatMulMatAdd{StyleA,StyleB,StyleC} = MulAdd{StyleA,StyleB,StyleC,<:Any,<:AbstractMatrix,<:AbstractMatrix,<:AbstractMatrix}
const VecMulMatAdd{StyleA,StyleB,StyleC} = MulAdd{StyleA,StyleB,StyleC,<:Any,<:AbstractVector,<:AbstractMatrix,<:AbstractMatrix}

broadcastable(M::MulAdd) = M


const BlasMatMulVecAdd{StyleA,StyleB,StyleC,T<:BlasFloat} = MulAdd{StyleA,StyleB,StyleC,T,<:AbstractMatrix{T},<:AbstractVector{T},<:AbstractVector{T}}
const BlasMatMulMatAdd{StyleA,StyleB,StyleC,T<:BlasFloat} = MulAdd{StyleA,StyleB,StyleC,T,<:AbstractMatrix{T},<:AbstractMatrix{T},<:AbstractMatrix{T}}
const BlasVecMulMatAdd{StyleA,StyleB,StyleC,T<:BlasFloat} = MulAdd{StyleA,StyleB,StyleC,T,<:AbstractVector{T},<:AbstractMatrix{T},<:AbstractMatrix{T}}

muladd!(α, A, B, β, C) = materialize!(MulAdd(α, A, B, β, C))
materialize(M::MulAdd) = copy(instantiate(M))
copy(M::MulAdd) = copyto!(similar(M), M)

@inline function copyto!(dest::AbstractArray{T}, M::MulAdd) where T
    M.C === dest  || copyto!(dest, M.C)
    muladd!(M.α, M.A, M.B, M.β, dest)
end

@inline function copyto!(dest::AbstractArray{T}, M::MulAdd{<:Any,<:Any,ZerosLayout}) where T
    α,A,B,β,C = M.α, M.A, M.B, M.β, M.C  
    if !isbitstype(T) # instantiate
        dest .= β .* view(A,:,1) .* Ref(B[1])  # get shape right
    end
    muladd!(α, A, B, β, dest)
end

# Modified from LinearAlgebra._generic_matmatmul!
function tile_size(T, S, R)
    tile_size = 0
    if isbitstype(R) && isbitstype(T) && isbitstype(S)
        tile_size = floor(Int, sqrt(tilebufsize / max(sizeof(R), sizeof(S), sizeof(T))))
    end
    tile_size
end

function tiled_blasmul!(tile_size, α, A::AbstractMatrix{T}, B::AbstractMatrix{S}, β, C::AbstractMatrix{R}) where {S,T,R}
    mA, nA = size(A)
    mB, nB = size(B)
    nA == mB || throw(DimensionMismatch("Dimensions must match"))
    size(C) == (mA, nB) || throw(DimensionMismatch("Dimensions must match"))


    @inbounds begin
        sz = (tile_size, tile_size)
        # FIXME: This code is completely invalid!!!
        Atile = unsafe_wrap(Array, convert(Ptr{T}, pointer(Abuf[Threads.threadid()])), sz)
        Btile = unsafe_wrap(Array, convert(Ptr{S}, pointer(Bbuf[Threads.threadid()])), sz)

        z1 = zero(A[1, 1]*B[1, 1] + A[1, 1]*B[1, 1])
        z = convert(promote_type(typeof(z1), R), z1)

        if mA < tile_size && nA < tile_size && nB < tile_size
            copy_transpose!(Atile, 1:nA, 1:mA, 'N', A, 1:mA, 1:nA)
            copyto!(Btile, 1:mB, 1:nB, 'N', B, 1:mB, 1:nB)
            for j = 1:nB
                boff = (j-1)*tile_size
                for i = 1:mA
                    aoff = (i-1)*tile_size
                    s = z
                    for k = 1:nA
                        s += Atile[aoff+k] * Btile[boff+k]
                    end
                    C[i,j] = α*s + β*C[i,j]
                end
            end
        else
            # FIXME: This code is completely invalid!!!
            Ctile = unsafe_wrap(Array, convert(Ptr{R}, pointer(Cbuf[Threads.threadid()])), sz)
            for jb = 1:tile_size:nB
                jlim = min(jb+tile_size-1,nB)
                jlen = jlim-jb+1
                for ib = 1:tile_size:mA
                    ilim = min(ib+tile_size-1,mA)
                    ilen = ilim-ib+1
                    copyto!(Ctile, 1:ilen, 1:jlen, C, ib:ilim, jb:jlim)
                    lmul!(β,Ctile)
                    for kb = 1:tile_size:nA
                        klim = min(kb+tile_size-1,mB)
                        klen = klim-kb+1
                        copy_transpose!(Atile, 1:klen, 1:ilen, 'N', A, ib:ilim, kb:klim)
                        copyto!(Btile, 1:klen, 1:jlen, 'N', B, kb:klim, jb:jlim)
                        for j=1:jlen
                            bcoff = (j-1)*tile_size
                            for i = 1:ilen
                                aoff = (i-1)*tile_size
                                s = z
                                for k = 1:klen
                                    s += Atile[aoff+k] * Btile[bcoff+k]
                                end
                                Ctile[bcoff+i] += α*s
                            end
                        end
                    end
                    copyto!(C, ib:ilim, jb:jlim, Ctile, 1:ilen, 1:jlen)
                end
            end
        end
    end

    C
end

function default_blasmul!(α, A::AbstractMatrix, B::AbstractMatrix, β, C::AbstractMatrix)
    mA, nA = size(A)
    mB, nB = size(B)
    nA == mB || throw(DimensionMismatch("Dimensions must match"))
    size(C) == (mA, nB) || throw(DimensionMismatch("Dimensions must match"))

    @inbounds for k in colsupport(A), j in rowsupport(B)
        z2 = zero(A[k, 1]*B[1, j] + A[k, 1]*B[1, j])
        Ctmp = convert(promote_type(eltype(C), typeof(z2)), z2)
        @simd for ν = rowsupport(A,k) ∩ colsupport(B,j)
            Ctmp = muladd(A[k, ν],B[ν, j],Ctmp)
        end
        C[k,j] = muladd(α,Ctmp, β*C[k,j])
    end
    C
end

function default_blasmul!(α, A::AbstractMatrix, B::AbstractVector, β, C::AbstractVector)
    mA, nA = size(A)
    mB = length(B)
    nA == mB || throw(DimensionMismatch("Dimensions must match"))
    length(C) == mA || throw(DimensionMismatch("Dimensions must match"))

    lmul!(β, C)
    (nA == 0 || mB == 0)  && return C

    z = zero(A[1]*B[1] + A[1]*B[1])
    Astride = size(A, 1) # use size, not stride, since its not pointer arithmetic

    @inbounds for k in colsupport(B,1)
        aoffs = (k-1)*Astride
        b = B[k]
        for i = 1:mA
            C[i] += α * A[aoffs + i] * b
        end
    end

    C
end

function materialize!(M::MatMulMatAdd)
    α, A, B, β, C = M.α, M.A, M.B, M.β, M.C
    if C ≡ B
        B = copy(B)
    end
    ts = tile_size(eltype(A), eltype(B), eltype(C))
    if iszero(β) # false is a "strong" zero to wipe out NaNs
        if ts == 0 || !(axes(A) isa NTuple{2,OneTo{Int}}) || !(axes(B) isa NTuple{2,OneTo{Int}}) || !(axes(C) isa NTuple{2,OneTo{Int}})
            default_blasmul!(α, A, B, false, C) 
        else 
            tiled_blasmul!(ts, α, A, B, false, C)
        end
    else
        if ts == 0 || !(axes(A) isa NTuple{2,OneTo{Int}}) || !(axes(B) isa NTuple{2,OneTo{Int}}) || !(axes(C) isa NTuple{2,OneTo{Int}})
            default_blasmul!(α, A, B, β, C) 
        else
            tiled_blasmul!(ts, α, A, B, β, C)
        end
    end
end

function materialize!(M::MatMulVecAdd)
    α, A, B, β, C = M.α, M.A, M.B, M.β, M.C
    if C ≡ B
        B = copy(B)
    end
    default_blasmul!(α, A, B, iszero(β) ? false : β, C)
end

# make copy to make sure always works
@inline function _gemv!(tA, α, A, x, β, y)
    if x ≡ y
        BLAS.gemv!(tA, α, A, copy(x), β, y)
    else
        BLAS.gemv!(tA, α, A, x, β, y)
    end
end

# make copy to make sure always works
@inline function _gemm!(tA, tB, α, A, B, β, C)
    if B ≡ C
        BLAS.gemm!(tA, tB, α, A, copy(B), β, C)
    else
        BLAS.gemm!(tA, tB, α, A, B, β, C)
    end
end


@inline materialize!(M::BlasMatMulVecAdd{<:AbstractColumnMajor,<:AbstractStridedLayout,<:AbstractStridedLayout}) =
    _gemv!('N', M.α, M.A, M.B, M.β, M.C)
@inline materialize!(M::BlasMatMulVecAdd{<:AbstractRowMajor,<:AbstractStridedLayout,<:AbstractStridedLayout}) =
    _gemv!('T', M.α, transpose(M.A), M.B, M.β, M.C)
@inline materialize!(M::BlasMatMulVecAdd{<:ConjLayout{<:AbstractRowMajor},<:AbstractStridedLayout,<:AbstractStridedLayout,<:BlasComplex}) =
    _gemv!('C', M.α, M.A', M.B, M.β, M.C)

@inline materialize!(M::BlasVecMulMatAdd{<:AbstractColumnMajor,<:AbstractColumnMajor,<:AbstractColumnMajor}) =
    _gemm!('N', 'N', M.α, M.A, M.B, M.β, M.C)
@inline materialize!(M::BlasVecMulMatAdd{<:AbstractColumnMajor,<:AbstractRowMajor,<:AbstractColumnMajor}) =
    _gemm!('N', 'T', M.α, M.A, transpose(M.B), M.β, M.C)
@inline materialize!(M::BlasVecMulMatAdd{<:AbstractColumnMajor,<:ConjLayout{<:AbstractRowMajor},<:AbstractColumnMajor,<:BlasComplex}) =
    _gemm!('N', 'C', M.α, M.A, M.B', M.β, M.C)

@inline materialize!(M::BlasMatMulMatAdd{<:AbstractColumnMajor,<:AbstractColumnMajor,<:AbstractColumnMajor}) =
    _gemm!('N', 'N', M.α, M.A, M.B, M.β, M.C)
@inline materialize!(M::BlasMatMulMatAdd{<:AbstractColumnMajor,<:AbstractRowMajor,<:AbstractColumnMajor}) =
    _gemm!('N', 'T', M.α, M.A, transpose(M.B), M.β, M.C)
@inline materialize!(M::BlasMatMulMatAdd{<:AbstractColumnMajor,<:ConjLayout{<:AbstractRowMajor},<:AbstractColumnMajor,<:BlasComplex}) =
    _gemm!('N', 'C', M.α, M.A, M.B', M.β, M.C)

@inline materialize!(M::BlasMatMulMatAdd{<:AbstractRowMajor,<:AbstractColumnMajor,<:AbstractColumnMajor}) =
    _gemm!('T', 'N', M.α, transpose(M.A), M.B, M.β, M.C)
@inline materialize!(M::BlasMatMulMatAdd{<:ConjLayout{<:AbstractRowMajor},<:AbstractColumnMajor,<:AbstractColumnMajor,<:BlasComplex}) =
    _gemm!('C', 'N', M.α, M.A', M.B, M.β, M.C)

@inline materialize!(M::BlasMatMulMatAdd{<:AbstractRowMajor,<:AbstractRowMajor,<:AbstractColumnMajor}) =
    _gemm!('T', 'T', M.α, transpose(M.A), transpose(M.B), M.β, M.C)
@inline materialize!(M::BlasMatMulMatAdd{<:AbstractRowMajor,<:ConjLayout{<:AbstractRowMajor},<:AbstractColumnMajor,<:BlasComplex}) =
    _gemm!('T', 'C', M.α, transpose(M.A), M.B', M.β, M.C)

@inline materialize!(M::BlasMatMulMatAdd{<:ConjLayout{<:AbstractRowMajor},<:AbstractRowMajor,<:AbstractColumnMajor,<:BlasComplex}) =
    _gemm!('C', 'T', M.α, M.A', M.B', M.β, M.C)
@inline materialize!(M::BlasMatMulMatAdd{<:ConjLayout{<:AbstractRowMajor},<:ConjLayout{<:AbstractRowMajor},<:AbstractColumnMajor,<:BlasComplex}) =
    _gemm!('C', 'C', M.α, M.A', M.B', M.β, M.C)

@inline materialize!(M::BlasMatMulMatAdd{<:AbstractColumnMajor,<:AbstractColumnMajor,<:AbstractRowMajor}) =
    _gemm!('T', 'T', M.α, M.B, M.A, M.β, transpose(M.C))
@inline materialize!(M::BlasMatMulMatAdd{<:AbstractColumnMajor,<:AbstractColumnMajor,<:ConjLayout{<:AbstractRowMajor},<:BlasComplex}) =
    _gemm!('C', 'C', M.α, M.B, M.A, M.β, M.C')

@inline materialize!(M::BlasMatMulMatAdd{<:AbstractColumnMajor,<:AbstractRowMajor,<:AbstractRowMajor}) =
    _gemm!('N', 'T', M.α, transpose(M.B), M.A, M.β, transpose(M.C))
@inline materialize!(M::BlasMatMulMatAdd{<:AbstractColumnMajor,<:AbstractRowMajor,<:ConjLayout{<:AbstractRowMajor},<:BlasComplex}) =
    _gemm!('N', 'T', M.α, transpose(M.B), M.A, M.β, M.C')
@inline materialize!(M::BlasMatMulMatAdd{<:AbstractColumnMajor,<:ConjLayout{<:AbstractRowMajor},<:ConjLayout{<:AbstractRowMajor},<:BlasComplex}) =
    _gemm!('N', 'C', M.α, M.B', M.A, M.β, M.C')

@inline materialize!(M::BlasMatMulMatAdd{<:AbstractRowMajor,<:AbstractColumnMajor,<:AbstractRowMajor}) =
    _gemm!('T', 'N', M.α, M.B, transpose(M.A), M.β, transpose(M.C))
@inline materialize!(M::BlasMatMulMatAdd{<:ConjLayout{<:AbstractRowMajor},<:AbstractColumnMajor,<:ConjLayout{<:AbstractRowMajor},<:BlasComplex}) =
    _gemm!('C', 'N', M.α, M.B, M.A', M.β, M.C')


@inline materialize!(M::BlasMatMulMatAdd{<:AbstractRowMajor,<:AbstractRowMajor,<:AbstractRowMajor}) =
    _gemm!('N', 'N', M.α, transpose(M.B), transpose(M.A), M.β, transpose(M.C))
@inline materialize!(M::BlasMatMulMatAdd{<:ConjLayout{<:AbstractRowMajor},<:ConjLayout{<:AbstractRowMajor},<:ConjLayout{<:AbstractRowMajor},<:BlasComplex}) =
    _gemm!('N', 'N', M.α, M.B', M.A', M.β, M.C')


###
# Symmetric
###

# make copy to make sure always works
@inline function _symv!(tA, α, A, x, β, y)
    if x ≡ y
        BLAS.symv!(tA, α, A, copy(x), β, y)
    else
        BLAS.symv!(tA, α, A, x, β, y)
    end
end

@inline function _hemv!(tA, α, A, x, β, y)
    if x ≡ y
        BLAS.hemv!(tA, α, A, copy(x), β, y)
    else
        BLAS.hemv!(tA, α, A, x, β, y)
    end
end


materialize!(M::BlasMatMulVecAdd{<:SymmetricLayout{<:AbstractColumnMajor},<:AbstractStridedLayout,<:AbstractStridedLayout}) =
    _symv!(symmetricuplo(M.A), M.α, symmetricdata(M.A), M.B, M.β, M.C)


materialize!(M::BlasMatMulVecAdd{<:SymmetricLayout{<:AbstractRowMajor},<:AbstractStridedLayout,<:AbstractStridedLayout}) =
    _symv!(symmetricuplo(M.A) == 'L' ? 'U' : 'L', M.α, transpose(symmetricdata(M.A)), M.B, M.β, M.C)


materialize!(M::BlasMatMulVecAdd{<:HermitianLayout{<:AbstractColumnMajor},<:AbstractStridedLayout,<:AbstractStridedLayout,<:BlasComplex}) =
    _hemv!(symmetricuplo(M.A), M.α, hermitiandata(M.A), M.B, M.β, M.C)

materialize!(M::BlasMatMulVecAdd{<:HermitianLayout{<:AbstractRowMajor},<:AbstractStridedLayout,<:AbstractStridedLayout,<:BlasComplex}) =
    _hemv!(symmetricuplo(M.A) == 'L' ? 'U' : 'L', M.α, hermitiandata(M.A)', M.B, M.β, M.C)


####
# Diagonal
####

# Diagonal multiplication never changes structure
similar(M::MulAdd{<:DiagonalLayout,<:DiagonalLayout}, ::Type{T}, axes) where T = similar(M.B, T, axes)
similar(M::MulAdd{<:DiagonalLayout}, ::Type{T}, axes) where T = similar(M.B, T, axes)
similar(M::MulAdd{<:Any,<:DiagonalLayout}, ::Type{T}, axes) where T = similar(M.A, T, axes)
# equivalent to rescaling
function materialize!(M::MulAdd{<:DiagonalLayout{<:AbstractFillLayout}})
    M.C .= (M.α * getindex_value(M.A.diag)) .* M.B .+ M.β .* M.C
    M.C
end

function materialize!(M::MulAdd{<:Any,<:DiagonalLayout{<:AbstractFillLayout}})
    M.C .= M.α .* M.A .* getindex_value(M.B.diag) .+ M.β .* M.C
    M.C
end

copy(M::MulAdd{<:DiagonalLayout{<:AbstractFillLayout}}) = (M.α * getindex_value(M.A.diag)) .* M.B .+ M.β .* M.C
copy(M::MulAdd{<:DiagonalLayout{<:AbstractFillLayout},<:Any,ZerosLayout}) = (M.α * getindex_value(M.A.diag)) .* M.B
copy(M::MulAdd{<:AbstractFillLayout,<:AbstractFillLayout,<:AbstractFillLayout}) = M.α*M.A*M.B + M.β*M.C
copy(M::MulAdd{<:Any,<:DiagonalLayout{<:AbstractFillLayout}}) = (M.α * getindex_value(M.B.diag)) .* M.A .+ M.β .* M.C
copy(M::MulAdd{<:Any,<:DiagonalLayout{<:AbstractFillLayout},ZerosLayout}) = (M.α * getindex_value(M.B.diag)) .* M.A

BroadcastStyle(::Type{<:MulAdd}) = ApplyBroadcastStyle()

scalarone(::Type{T}) where T = one(T)
scalarone(::Type{<:AbstractArray{T}}) where T = scalarone(T)
scalarzero(::Type{T}) where T = zero(T)
scalarzero(::Type{<:AbstractArray{T}}) where T = scalarzero(T)

fillzeros(::Type{T}, ax) where T = Zeros{T}(ax)

function mul!(dest::AbstractArray{W}, A::AbstractArray{T}, b::AbstractArray{V}) where {T,V,W} 
    TVW = promote_type(W, _mul_eltype(T,V))
    muladd!(scalarone(TVW), A, b, scalarzero(TVW), dest)
end

function MulAdd(A::AbstractArray{T}, B::AbstractVector{V}) where {T,V}
    TV = _mul_eltype(eltype(A), eltype(B))
    MulAdd(scalarone(TV), A, B, scalarzero(TV), fillzeros(TV,(axes(A,1))))
end

function MulAdd(A::AbstractArray{T}, B::AbstractMatrix{V}) where {T,V}
    TV = _mul_eltype(eltype(A), eltype(B))
    MulAdd(scalarone(TV), A, B, scalarzero(TV), fillzeros(TV,(axes(A,1),axes(B,2))))
end

mul(A::AbstractArray, B::AbstractArray) = materialize(MulAdd(A,B))

macro lazymul(Typ)
    ret = quote
        LinearAlgebra.mul!(dest::AbstractVector, A::$Typ, b::AbstractVector) =
            ArrayLayouts.mul!(dest,A,b)

        LinearAlgebra.mul!(dest::AbstractMatrix, A::$Typ, b::AbstractMatrix) =
            ArrayLayouts.mul!(dest,A,b)
        LinearAlgebra.mul!(dest::AbstractMatrix, A::$Typ, b::$Typ) =
            ArrayLayouts.mul!(dest,A,b)

        Base.:*(A::$Typ, B::$Typ) = ArrayLayouts.mul(A,B)
        Base.:*(A::$Typ, B::AbstractMatrix) = ArrayLayouts.mul(A,B)
        Base.:*(A::$Typ, B::AbstractVector) = ArrayLayouts.mul(A,B)
        Base.:*(A::AbstractMatrix, B::$Typ) = ArrayLayouts.mul(A,B)
        Base.:*(A::LinearAlgebra.AdjointAbsVec, B::$Typ) = ArrayLayouts.mul(A,B)
        Base.:*(A::LinearAlgebra.TransposeAbsVec, B::$Typ) = ArrayLayouts.mul(A,B)

        Base.:*(A::LinearAlgebra.AbstractQ, B::$Typ) = ArrayLayouts.lmul(A,B)
        Base.:*(A::$Typ, B::LinearAlgebra.AbstractQ) = ArrayLayouts.rmul(A,B)
    end
    for Struc in (:AbstractTriangular, :Diagonal)
        ret = quote
            $ret

            Base.:*(A::LinearAlgebra.$Struc, B::$Typ) = ArrayLayouts.mul(A,B)
            Base.:*(A::$Typ, B::LinearAlgebra.$Struc) = ArrayLayouts.mul(A,B)
        end
    end
    for Mod in (:Adjoint, :Transpose, :Symmetric, :Hermitian)
        ret = quote
            $ret

            LinearAlgebra.mul!(dest::AbstractMatrix, A::$Typ, b::$Mod{<:Any,<:AbstractMatrix}) =
                ArrayLayouts.mul!(dest,A,b)

            LinearAlgebra.mul!(dest::AbstractVector, A::$Mod{<:Any,<:$Typ}, b::AbstractVector) =
                ArrayLayouts.mul!(dest,A,b)

            Base.:*(A::$Mod{<:Any,<:$Typ}, B::$Mod{<:Any,<:$Typ}) = ArrayLayouts.mul(A,B)
            Base.:*(A::$Mod{<:Any,<:$Typ}, B::AbstractMatrix) = ArrayLayouts.mul(A,B)
            Base.:*(A::AbstractMatrix, B::$Mod{<:Any,<:$Typ}) = ArrayLayouts.mul(A,B)
            Base.:*(A::$Mod{<:Any,<:$Typ}, B::AbstractVector) = ArrayLayouts.mul(A,B)

            Base.:*(A::$Mod{<:Any,<:$Typ}, B::$Typ) = ArrayLayouts.mul(A,B)
            Base.:*(A::$Typ, B::$Mod{<:Any,<:$Typ}) = ArrayLayouts.mul(A,B)

            Base.:*(A::$Mod{<:Any,<:$Typ}, B::Diagonal) = ArrayLayouts.mul(A,B)
            Base.:*(A::Diagonal, B::$Mod{<:Any,<:$Typ}) = ArrayLayouts.mul(A,B)

            Base.:*(A::LinearAlgebra.AbstractTriangular, B::$Mod{<:Any,<:$Typ}) = ArrayLayouts.mul(A,B)
            Base.:*(A::$Mod{<:Any,<:$Typ}, B::LinearAlgebra.AbstractTriangular) = ArrayLayouts.mul(A,B)
        end
    end

    esc(ret)
end