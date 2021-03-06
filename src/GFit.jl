module GFit

using Printf, PrettyTables
using Statistics, Distributions
using DataStructures
using LsqFit
using MacroTools
using Dates
using ProgressMeter

import Base.show
import Base.ndims
import Base.size
import Base.length
import Base.haskey
import Base.keys
import Base.getindex
import Base.setindex!
import Base.reshape
import Base.propertynames
import Base.getproperty
import Base.setproperty!
import Base.iterate
import Base.push!

export Domain, CartesianDomain, coords, axis, roi, int_tabulated, Measures,
    Model, @expr, SumReducer, select_reducer!, domain,
    MultiModel, @patch!, evaluate!, isfixed, thaw, freeze, fit!


include("domain.jl")
include("HashVector.jl")

# ====================================================================
mutable struct ExprFunction
    expr::Expr
    funct::Function
    args::Vector{Symbol}
end

macro exprfunc(_expr)
    @assert isexpr(longdef(_expr), :function)
    expr = prettify(_expr)
    args = convert(Vector{Symbol}, splitdef(expr)[:args])
    return esc(:(GFit.ExprFunction($(QuoteNode(expr)), $expr, $args)))
end


# ====================================================================
# Parameter and component identifiers
struct ParamID
    name::Symbol
    index::Int
    ParamID(pname::Symbol) = new(pname, 0)                  # scalar param
    ParamID(pname::Symbol, index::Int) = new(pname, index)  # vector of params
end

struct CompParamID
    cname::Symbol
    param::ParamID
end

mutable struct Parameter
    val::Float64
    low::Float64              # lower limit value
    high::Float64             # upper limit value
    step::Float64
    fixed::Bool
    Parameter(value::Number) = new(float(value), -Inf, +Inf, NaN, false)
end


# ====================================================================
# Components:
#
# A *component* is a generic implementation of a building block for a
# model. It must inherit `AbstractComponent` and implement the
# `evaluate!` method (optionally also `prepare!`).  The structure may
# contain zero or more field of type Parameter (see above)
abstract type AbstractComponent end

function getparams(comp::AbstractComponent)
    params = OrderedDict{ParamID, Parameter}()
        for pname in fieldnames(typeof(comp))
            par = getfield(comp, pname)
            if isa(par, Parameter)
                params[ParamID(pname)] = par
            elseif isa(par, Vector{Parameter})
                for i in 1:length(par)
                    params[ParamID(pname, i)] = par[i]
                end
            end
        end
    return params
end

# CompEval: a wrapper for a component evaluated on a specific domain
mutable struct CompEval{TComp <: AbstractComponent, TDomain <: AbstractDomain}
    comp::TComp
    domain::TDomain
    params::OrderedDict{ParamID, Parameter}
    counter::Int
    lastvalues::Vector{Float64}
    buffer::Vector{Float64}
    cfixed::Bool

    function CompEval(_comp::AbstractComponent, domain::AbstractDomain)
        # Components internal state may be affected by `prepare!`
        # call.  Avoid overwriting input state with a deep copy.
        comp = deepcopy(_comp)

        params = getparams(comp)
        buffer = prepare!(comp, domain)
        return new{typeof(comp), typeof(domain)}(
            comp, domain, params, 0,
            fill(NaN, length(params)),
            buffer, false)
    end
end


# Fall back method
prepare!(comp::AbstractComponent, domain::AbstractDomain) = fill(NaN, length(domain))
#evaluate!(buffer::Vector{Float64}, comp::T, domain::AbstractDomain, pars...) where T =
#    error("No evaluate! method implemented for $T")

function evaluate_cached(c::CompEval, pvalues::Vector{Float64})
    @assert length(c.params) == length(pvalues)

    # Do we actually need a new evaluation?
    if (any(c.lastvalues .!= pvalues)  ||  (c.counter == 0))
        c.lastvalues .= pvalues
        c.counter += 1
        if !all(.!isnan.(pvalues))
            println("One or more parameter value(s) are NaN:")
            println(pvalues)
            @assert all(.!isnan.(pvalues))
        end
        evaluate!(c.buffer, c.comp, c.domain, pvalues...)
    end
    return c.buffer
end

# Built-in components
#
include("components/utils.jl")
include("components/CDomain.jl")
include("components/SimplePar.jl")
include("components/FuncWrap.jl")
include("components/OffsetSlope.jl")
include("components/Gaussian.jl")
include("components/Lorentzian.jl")


# ====================================================================
# Reducer
#

abstract type AbstractReducer end

prepare!(red::AbstractReducer, domain::AbstractDomain, args::OrderedDict{Symbol, Vector{Float64}}) =
    fill(NaN, length(domain))


struct ExprReducer <: AbstractReducer
    ef::ExprFunction
    function ExprReducer(ef::ExprFunction)
        @assert length(ef.args) == 1
        new(ef)
    end
end

prepare!(red::ExprReducer, domain::AbstractDomain, args::OrderedDict{Symbol, Vector{Float64}}) =
    fill(NaN, length(red.ef.funct(args)))

function evaluate!(buffer::Vector{Float64}, red::ExprReducer,
                   domain::AbstractDomain, args::OrderedDict{Symbol, Vector{Float64}})
    buffer .= red.ef.funct(args)
    nothing
end

macro expr(expr)
    return esc(:(GFit.ExprReducer(GFit.@exprfunc $expr)))
end


struct SumReducer <: AbstractReducer
    list::Vector{Symbol}
end

function evaluate!(buffer::Vector{Float64}, red::SumReducer,
                   domain::AbstractDomain, args::OrderedDict{Symbol, Vector{Float64}})
    buffer .= 0.
    for name in red.list
        buffer .+= args[name]
    end
    nothing
end


mutable struct ReducerEval{T <: AbstractReducer}
    red::T
    counter::Int
    buffer::Vector{Float64}
end


# ====================================================================
# Model
#

const PatchComp = HashVector{Float64}

struct ModelEval
    pvalues::Vector{Float64}
    patched::Vector{Float64}
    patchcomps::OrderedDict{Symbol, PatchComp}
    reducer_args::OrderedDict{Symbol, Vector{Float64}}

    ModelEval() =
        new(Vector{Float64}(), Vector{Float64}(),
            OrderedDict{Symbol, PatchComp}(),
            OrderedDict{Symbol, Vector{Float64}}())
end

abstract type AbstractMultiModel end

# A model prediction suitable to be compared to a single empirical dataset
mutable struct Model
    parent::Union{Nothing, AbstractMultiModel}
    domain::AbstractDomain
    cevals::OrderedDict{Symbol, CompEval}
    revals::OrderedDict{Symbol, ReducerEval}
    rsel::Symbol
    patchfuncts::Vector{ExprFunction}
    peval::ModelEval

    function Model(domain::AbstractDomain, args...)
        function parse_args(args::AbstractDict)
            out = OrderedDict{Symbol, Union{AbstractComponent, AbstractReducer}}()
            for (name, item) in args
                isa(item, Number)  &&  (item = SimplePar(item))
                @assert isa(name, Symbol)
                @assert isa(item, AbstractComponent) || isa(item, AbstractReducer)
                out[name] = item
            end
            return out
        end

        function parse_args(args::Vararg{Pair})
            out = OrderedDict{Symbol, Union{AbstractComponent, AbstractReducer}}()
            for arg in args
                out[arg[1]] = arg[2]
            end
            return parse_args(out)
        end

        model = new(nothing, domain,
                    OrderedDict{Symbol, CompEval}(),
                    OrderedDict{Symbol, ReducerEval}(),
                    Symbol(""),
                    Vector{ExprFunction}(),
                    ModelEval())
        for (name, item) in parse_args(args...)
            model[name] = item
        end
        if length(model.revals) == 0
            model[:default_sum] = SumReducer(collect(keys(model.cevals)))
        end
        return model
    end
end


function setindex!(model::Model, comp::AbstractComponent, cname::Symbol)
    @assert !haskey(model.revals, cname)  "Name $cname already exists as a reducer name"
    ceval = CompEval(deepcopy(comp), model.domain)
    model.cevals[cname] = ceval
    evaluate!(model)
end

function setindex!(model::Model, reducer::T, rname::Symbol) where T <: AbstractReducer
    @assert !haskey(model.cevals, rname) "Name $rname already exists as a component name"
    model.revals[rname] = ReducerEval{T}(reducer, 1, prepare!(reducer, model.domain, model.peval.reducer_args))
    (model.rsel == Symbol(""))  &&  (model.rsel = rname)
    evaluate!(model)
    return model
end


function select_reducer!(model::Model, rname::Symbol)
    @assert haskey(model.revals, rname) "$rname is not a reducer name"
    model.rsel = rname
end


function geteval(model::Model, name::Symbol)
    if haskey(model.cevals, name)
        return model.cevals[name].buffer
    else
        if haskey(model.revals, name)
            return model.revals[name].buffer
        else
            return Float64[]
        end
    end
end

geteval(model::Model) = geteval(model, model.rsel)


function evaluate!(model::Model)
    # Update peval structure
    empty!(model.peval.pvalues)
    empty!(model.peval.patched)
    empty!(model.peval.patchcomps)
    for (cname, ceval) in model.cevals
        model.peval.patchcomps[cname] = HashVector{Float64}(model.peval.patched)
        for (pid, par) in ceval.params
            push!(model.peval.pvalues, par.val)
            push!(model.peval.patchcomps[cname], pid.name, NaN)
        end
    end
    @assert length(model.peval.patched) == length(model.peval.pvalues)

    empty!(model.peval.reducer_args)
    for (cname, ceval) in model.cevals
        model.peval.reducer_args[cname] = ceval.buffer
    end
    for (rname, reval) in model.revals
        model.peval.reducer_args[rname] = reval.buffer
    end

    patch_params(model)
    quick_evaluate(model)

    return model
end

function patch_params(model::Model)
    if !isnothing(model.parent)
        patch_params(model.parent)
    else
        model.peval.patched .= model.peval.pvalues  # copy all values by default
        for pf in model.patchfuncts
            pf.funct(model.peval.patchcomps)
        end
    end
    nothing
end

function quick_evaluate(model::Model)
    i1 = 1
    for (cname, ceval) in model.cevals
        if length(ceval.params) > 0
            i2 = i1 + length(ceval.params) - 1
            evaluate_cached(ceval, model.peval.patched[i1:i2])
            i1 += length(ceval.params)
        else
            evaluate_cached(ceval, Float64[])
        end
    end

    for (rname, reval) in model.revals
        (rname == model.rsel)  &&  continue  # this should be evaluated as last one
        reval.counter += 1
        evaluate!(reval.buffer, reval.red, model.domain, model.peval.reducer_args)
    end

    if length(model.revals) > 0
        reval = model.revals[model.rsel]
        reval.counter += 1
        evaluate!(reval.buffer, reval.red, model.domain, model.peval.reducer_args)
    end
end

function patch!(model::Model, exfunc::ExprFunction)
    push!(model.patchfuncts, exfunc)
    evaluate!(model)
    return model
end

include("macro_patch.jl")

function isfixed(model::Model, cname::Symbol)
    @assert cname in keys(model.cevals) "Component $cname is not defined"
    return model.cevals[cname].cfixed
end

function freeze(model::Model, cname::Symbol)
    @assert cname in keys(model.cevals) "Component $cname is not defined"
    model.cevals[cname].cfixed = true
    evaluate!(model)
    nothing
end

function thaw(model::Model, cname::Symbol)
    @assert cname in keys(model.cevals) "Component $cname is not defined"
    model.cevals[cname].cfixed = false
    evaluate!(model)
    nothing
end


Base.keys(p::Model) = collect(keys(p.cevals))
Base.haskey(p::Model, name::Symbol) = haskey(p.cevals, name)
function Base.getindex(model::Model, name::Symbol)
    if name in keys(model.cevals)
        return model.cevals[name].comp
    elseif name in keys(model.revals)
        return model.revals[name].red
    end
    error("Name $name not defined")
end
domain(model::Model) = model.domain
(model::Model)() = geteval(model)
(model::Model)(name::Symbol) = geteval(model, name)


include("multimodel.jl")
include("minimizers.jl")
include("comparison.jl")
include("results.jl")
include("fit.jl")
include("show.jl")

end
