# same as `sum.jl`, but using the OrcJIT to compile the code and executing it via ccall.

using Test

using LLVM
using Base.Threads

const SUM_PTR = Ref{Ptr{Cvoid}}(C_NULL)
call_sum(x::Int32, y::Int32) = ccall(SUM_PTR[], Int32, (Int32, Int32), x, y)

const HOLE_PTRS = Dict{Int, Ref{Ptr{Cvoid}}}()
const HOLE_LOCK = ReentrantLock()

call_hole(id::Int, x::Int32, y::Int32) =
    ccall(HOLE_PTRS[id][], Int32, (Int32, Int32), x, y)

function register_hole!(id::Int, addr::Ptr{Cvoid})
    lock(HOLE_LOCK) do
        HOLE_PTRS[id] = get!(HOLE_PTRS, id, Ref{Ptr{Cvoid}}(C_NULL))
        HOLE_PTRS[id][] = addr
    end
end

function swap_hole!(id::Int, addr::Ptr{Cvoid})
    lock(HOLE_LOCK) do
        @assert haskey(HOLE_PTRS, id) "unknown HOLE $id"
        HOLE_PTRS[id][] = addr
    end
end

if length(ARGS) == 2
    x, y = parse.([Int32], ARGS[1:2])
else
    x = Int32(1)
    y = Int32(2)
end

function codegen!(mod::LLVM.Module, name, tm)
    param_types = [LLVM.Int32Type(), LLVM.Int32Type()]
    ret_type = LLVM.Int32Type()

    triple!(mod, triple(tm))

    ft = LLVM.FunctionType(ret_type, param_types)
    sum = LLVM.Function(mod, name, ft)

    # generate IR
    @dispose builder=IRBuilder() begin
        entry = BasicBlock(sum, "entry")
        position!(builder, entry)

        tmp = add!(builder, parameters(sum)[1], parameters(sum)[2], "tmp")
        ret!(builder, tmp)
    end

    verify(mod)

    @dispose pm=ModulePassManager() begin
        add_library_info!(pm, triple(mod))
        add_transform_info!(pm, tm)
        run!(pm, mod)
    end

    verify(mod)
end

function codegen2!(mod::LLVM.Module, name, tm)
    param_types = [LLVM.Int32Type(), LLVM.Int32Type()]
    ret_type = LLVM.Int32Type()

    triple!(mod, triple(tm))

    ft = LLVM.FunctionType(ret_type, param_types)
    sum = LLVM.Function(mod, name, ft)

    # generate IR
    @dispose builder=IRBuilder() begin
        entry = BasicBlock(sum, "entry")
        position!(builder, entry)

        tmp = sub!(builder, parameters(sum)[1], parameters(sum)[2], "tmp")
        ret!(builder, tmp)
    end

    verify(mod)

    @dispose pm=ModulePassManager() begin
        add_library_info!(pm, triple(mod))
        add_transform_info!(pm, tm)
        run!(pm, mod)
    end

    verify(mod)
end

tm = JITTargetMachine()
# XXX: LLJIT calls TargetMachineBuilder which disposes the TargetMachine
jit = LLJIT(; tm=JITTargetMachine())
jd = JITDylib(jit)

@dispose ts_ctx=ThreadSafeContext() begin
    ts_mod = ThreadSafeModule("jit")
    name = "sum_orc.jl"
    ts_mod() do mod
        codegen!(mod, name, tm)
    end

    add!(jit, jd, ts_mod)
    addr = lookup(jit, name)

    # @eval call_sum(x, y) = ccall($(pointer(addr)), Int32, (Int32, Int32), x, y)
    # SUM_PTR[] = pointer(addr)
    register_hole!(1, pointer(addr))
end

# @test call_sum(x, y) == x + y
# @test call_sum(Int32(1), Int32(2)) == 3
@test call_hole(1, x, y) == x + y
@test call_hole(1, Int32(1), Int32(2)) == 3

@dispose ts_ctx2=ThreadSafeContext() begin
    ts_mod_mul = ThreadSafeModule("overlay_jit")
    name = "sum_org_mod.jl"
    ts_mod_mul() do mod
        codegen2!(mod, name, tm)
    end

    add!(jit, jd, ts_mod_mul)
    addr = lookup(jit, name)
    # SUM_PTR[] = pointer(addr)
    register_hole!(1, pointer(addr))
end

@test call_hole(1, x, y) == x - y
@test call_hole(1, Int32(1), Int32(2)) == -1

LLVM.dispose(jit)
LLVM.dispose(tm)
