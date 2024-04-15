# script to parse CUDA headers and generate Julia wrappers
#
# Usage: julia --project=res/wrap res/wrap/wrap.jl [name]
#
# By default, all CUDA headers are wrapped. If `name` is given, e.g. `cuda` or `cublas`,
# only the corresponding headers are wrapped.
#
# To update the types of arguments, add `api.<function>.argtypes` to a library's TOML file.

# TODO
# - deal with NVML's `NVML_STRUCT_VERSION` (workaround: we ignore these symbols)

using Clang
using Clang.Generators

using JuliaFormatter

using CUDA_SDK_jll, CUDNN_jll, CUTENSOR_jll, cuQuantum_jll
using Libglvnd_jll

# a pass that removes macro definitions that are also function definitions.
#
# this sometimes happens with NVIDIA's headers, either because of typos, or because they are
# reserving identifiers for future use:
#   #define cuStreamGetCaptureInfo_v2 __CUDA_API_PTSZ(cuStreamGetCaptureInfo_v2)
mutable struct AvoidDuplicates <: Clang.AbstractPass end
function (x::AvoidDuplicates)(dag::ExprDAG, options::Dict)
    # collect macro definitions
    macro_definitions = Dict()
    for (i, node) in enumerate(dag.nodes)
        if node isa ExprNode{<:AbstractMacroNodeType}
            macro_definitions[node.id] = (i, node)
        end
    end

    # scan function definitions
    for (i, node) in enumerate(dag.nodes)
        if Generators.is_function(node) && !Generators.is_variadic_function(node)
            if haskey(macro_definitions, node.id)
                @info "Removing macro definition for $(node.id)"
                j, duplicate_node  = macro_definitions[node.id]
                dag.nodes[j] = ExprNode(node.id, Clang.Generators.Skip(), duplicate_node.cursor, duplicate_node.exprs, duplicate_node.adj)
            end
        end
    end

    return dag
end

function wrap(name, headers; targets=headers, defines=[], include_dirs=[])
    @info "Wrapping $name"

    args = get_default_args()
    append!(args, map(dir->"-I$dir", include_dirs))
    for define in defines
        if isa(define, Pair)
            append!(args, ["-D", "$(first(define))=$(last(define))"])
        else
            append!(args, ["-D", "$define"])
        end
    end

    options = load_options(joinpath(@__DIR__, "$(name).toml"))

    # create context
    ctx = create_context([headers...], args, options)

    insert!(ctx.passes, 2, AvoidDuplicates())

    # run generator
    build!(ctx, BUILDSTAGE_NO_PRINTING)

    # only keep the wrapped headers
    # NOTE: normally we'd do this by using `-isystem` instead of `-I` above,
    #       but in the case of CUDA most headers are in a single directory.
    replace!(get_nodes(ctx.dag)) do node
        path = normpath(Clang.get_filename(node.cursor))
        should_wrap = any(targets) do target
            occursin(target, path)
        end
        if !should_wrap
            return ExprNode(node.id, Generators.Skip(), node.cursor, Expr[], node.adj)
        end
        return node
    end

    rewriter!(ctx, options)

    build!(ctx, BUILDSTAGE_PRINTING_ONLY)

    output_file = options["general"]["output_file_path"]

    # prepend "autogenerated, do not edit!" comment
    output_data = read(output_file, String)
    open(output_file, "w") do io
        println(io, """# This file is automatically generated. Do not edit!
                       # To re-generated, execute res/wrap.jl""")
        println(io)
        print(io, output_data)
    end

    format_file(output_file, YASStyle())

    return
end

function rewriter!(ctx, options)
    for node in get_nodes(ctx.dag)
        # remove aliases for function names
        #
        # when NVIDIA changes the behavior of an API, they version the function
        # (`cuFunction_v2`), and sometimes even change function names. To maintain backwards
        # compatibility, they ship aliases with their headers such that compiled binaries
        # will keep using the old version, and newly-compiled ones will use the developer's
        # CUDA version. remove those, since we target multiple CUDA versions.
        #
        # remove this if we ever decide to support a single supported version of CUDA.
        if node isa ExprNode{<:AbstractMacroNodeType}
            isempty(node.exprs) && continue
            expr = node.exprs[1]
            if Meta.isexpr(expr, :const)
                expr = expr.args[1]
            end
            if Meta.isexpr(expr, :(=))
                lhs, rhs = expr.args
                if rhs isa Expr && rhs.head == :call
                    name = string(rhs.args[1])
                    if endswith(name, "STRUCT_SIZE")
                        rhs.head = :macrocall
                        rhs.args[1] = Symbol("@", name)
                        insert!(rhs.args, 2, nothing)
                    end
                end
                isa(lhs, Symbol) || continue
                if Meta.isexpr(rhs, :call) && rhs.args[1] in (:__CUDA_API_PTDS, :__CUDA_API_PTSZ)
                    rhs = rhs.args[2]
                end
                isa(rhs, Symbol) || continue
                lhs, rhs = String(lhs), String(rhs)
                function get_prefix(str)
                    # cuFooBar -> cu
                    isempty(str) && return nothing
                    islowercase(str[1]) || return nothing
                    for i in 2:length(str)
                        if isuppercase(str[i])
                            return str[1:i-1]
                        end
                    end
                    return nothing
                end
                lhs_prefix = get_prefix(lhs)
                lhs_prefix === nothing && continue
                rhs_prefix = get_prefix(rhs)
                if lhs_prefix == rhs_prefix
                    @debug "Removing function alias: `$expr`"
                    empty!(node.exprs)
                end
            end
        end

        if Generators.is_function(node) && !Generators.is_variadic_function(node)
            expr = node.exprs[1]
            call_expr = expr.args[2].args[1].args[3]    # assumes `use_ccall_macro` is true

            # replace `@ccall` with `@gcsafe_ccall`
            expr.args[2].args[1].args[1] = Symbol("@gcsafe_ccall")

            target_expr = call_expr.args[1].args[1]
            fn = String(target_expr.args[2].value)

            # look up API options for this function
            fn_options = Dict{String,Any}()
            templates = Dict{String,Any}()
            template_types = nothing
            if haskey(options, "api")
                names = [fn]

                # _64 aliases are used by CUBLAS with Int64 arguments. they otherwise have
                # an idential signature, so we can reuse the same type rewrites.
                if endswith(fn, "_64")
                    push!(names, fn[1:end-3])
                end

                # look for a template rewrite: many libraries have very similar functions,
                # e.g., `cublas[SDHCZ]gemm`, for which we can use the same type rewrites
                # registered as `cublas𝕏gemm` template with `T` and `S` placeholders.
                for name in copy(names),
                    (typcode,(T,S)) in ["S"=>("Cfloat","Cfloat"),
                                        "D"=>("Cdouble","Cdouble"),
                                        "H"=>("Float16","Float16"),
                                        "C"=>("cuComplex","Cfloat"),
                                        "Z"=>("cuDoubleComplex","Cdouble")]

                    start = 1
                    match = findnext(typcode, name, start)
                    while match !== nothing
                        idx = match.start
                        template_name = name[1:idx-1] * "𝕏" * name[idx+1:end]
                        if haskey(options["api"], template_name)
                            templates[template_name] = ["T" => T, "S" => S]
                            push!(names, template_name)
                        end

                        start = idx+1
                        match = findnext(typcode, name, start)
                    end
                end

                # the exact name is always checked first, so it's always possible to
                # override the type rewrites for a specific function
                # (e.g. if a _64 function ever passes a `Ptr{Cint}` index).
                for name in names
                    template_types = get(templates, name, nothing)
                    if haskey(options["api"], name)
                        fn_options = options["api"][name]
                        break
                    end
                end
            end

            # rewrite pointer argument types
            arg_exprs = call_expr.args[1].args[2:end]
            argtypes = get(fn_options, "argtypes", Dict())
            for (arg, typ) in argtypes
                i = parse(Int, arg)
                i in 1:length(arg_exprs) || error("invalid argtypes for $fn: index $arg is out of bounds")

                # _64 aliases should use Int64 instead of Int32/Cint
                if endswith(fn, "_64")
                    typ = replace(typ, "Cint" => "Int64", "Int32" => "Int64")
                end

                # expand type templates
                if template_types !== nothing
                    typ = replace(typ, template_types...)
                end

                arg_exprs[i].args[2] = Meta.parse(typ)
            end

            # insert `initialize_context()` before each function with a `ccall`
            if get(fn_options, "needs_context", true)
                pushfirst!(expr.args[2].args, :(initialize_context()))
            end

            # insert `@checked` before each function with a `ccall` returning a checked type`
            rettyp = call_expr.args[2]
            checked_types = if haskey(options, "api")
                get(options["api"], "checked_rettypes", Dict())
            else
                String[]
            end
            if rettyp isa Symbol && String(rettyp) in checked_types
                node.exprs[1] = Expr(:macrocall, Symbol("@checked"), nothing, expr)
            end
        end
    end
end

function main(name="all")
    cuda = joinpath(CUDA_SDK_jll.artifact_dir, "cuda", "include")
    @assert CUDA_SDK_jll.is_available()

    opengl = joinpath(Libglvnd_jll.artifact_dir, "include")
    @assert Libglvnd_jll.is_available()

    if name == "all" || name == "cudadrv"
        wrap("cuda", ["$cuda/cuda.h","$cuda/cudaGL.h","$cuda/cudaProfiler.h"];
            include_dirs=[cuda, opengl])
    end

    if name == "all" || name == "nvml"
        wrap("nvml", ["$cuda/nvml.h"]; include_dirs=[cuda])
    end

    if name == "all" || name == "cupti"
        cupti = joinpath(CUDA_SDK_jll.artifact_dir, "cuda", "include")

        wrap("cupti", ["$cupti/cupti.h", "$cupti/cupti_profiler_target.h"];
            include_dirs=[cuda, cupti],
            targets=[r"cupti_.*.h"])
    end

    if name == "all" || name == "cublas"
        wrap("cublas", ["$cuda/cublas_v2.h", "$cuda/cublasXt.h", "$cuda/cublasLt.h"];
            targets=[r"cublas.*.h"],
            include_dirs=[cuda])
    end


    if name == "all" || name == "cufft"
        wrap("cufft", ["$cuda/cufft.h"]; include_dirs=[cuda])
    end

    if name == "all" || name == "curand"
        wrap("curand", ["$cuda/curand.h"]; include_dirs=[cuda])
    end

    if name == "all" || name == "cusparse"
        wrap("cusparse", ["$cuda/cusparse.h"]; include_dirs=[cuda],
              defines=["DISABLE_CUSPARSE_DEPRECATED=1"])
    end

    if name == "all" || name == "cusolver"
        wrap("cusolver",
            ["$cuda/cusolverDn.h", "$cuda/cusolverSp.h",
             "$cuda/cusolverSp_LOWLEVEL_PREVIEW.h"];
            targets=[r"cusolver.*.h"],
            include_dirs=[cuda],
            defines=["DISABLE_CUSPARSE_DEPRECATED=1"])

        wrap("cusolverRF", ["$cuda/cusolverRf.h"]; include_dirs=[cuda])

        wrap("cusolverMg", ["$cuda/cusolverMg.h"]; include_dirs=[cuda])
    end

    if (name == "all" || name == "cudnn") && CUDNN_jll.is_available()
        cudnn = joinpath(CUDNN_jll.artifact_dir, "include")
        wrap("cudnn",
            ["$cudnn/cudnn.h"]; targets=[r"cudnn_.*.h"],
             include_dirs=[cuda, cudnn])
    end

    if (name == "all" || name == "cutensor") && CUTENSOR_jll.is_available()
        cutensor = joinpath(CUTENSOR_jll.artifact_dir, "include")
        wrap("cutensor", ["$cutensor/cutensor.h"];
            targets=["cutensor.h", "cutensor/types.h"],
            include_dirs=[cuda, cutensor])
    end

    if cuQuantum_jll.is_available()
        cuquantum = joinpath(cuQuantum_jll.artifact_dir, "include")

        if name == "all" || name == "cutensornet"
            wrap("cutensornet", ["$cuquantum/cutensornet.h"];
                targets=["cutensornet.h", "cutensornet/types.h"],
                include_dirs=[cuda, cuquantum])
        end

        if name == "all" || name == "custatevec"
            wrap("custatevec", ["$cuquantum/custatevec.h"];
                targets=["custatevec.h", "custatevec/types.h"],
                include_dirs=[cuda, cuquantum])
        end
    end

end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS...)
end
