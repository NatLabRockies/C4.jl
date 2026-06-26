module DispatchModel

import JuMP
import JuMP: @variable, @constraint, @expression, @objective, value

import IterTools: zip_longest

import ..DispatchableThermalTech, ..DispatchableVariableTech,
       ..DispatchableStorageTech, ..DispatchableSystem,
       ..JuMP_ExpressionRef, ..JuMP_LessThanConstraintRef,
       ..JuMP_GreaterThanConstraintRef, ..JuMP_EqualToConstraintRef, ..varnames!,
       ..availablecapacity, ..nameplatecapacity, ..maxpower, ..maxenergy,
       ..roundtrip_efficiency, ..operating_cost, ..max_unit_ramp, ..num_units,
       ..unit_size, ..min_gen, ..min_uptime, ..min_downtime,
       ..name, ..cost, ..co2, ..cost_generation, ..cost_startup,
       ..co2_generation, ..co2_startup, ..demand,
       ..variabletechs, ..storagetechs, ..thermaltechs,
       ..solve!, ..powerunits_MW, ..N_HOURS_IN_DAY

import ..Data: annualization_factor

using ..Data

include("time.jl")
include("representative_periods.jl")
include("dispatch.jl")
include("sequencing.jl")

export DispatchProblem, DispatchSequence, DispatchDay, DispatchProxyMapping,
       singleperiod, seasonalperiods, monthlyperiods, weeklyperiods,
       seasonalperiods_byyear, monthlyperiods_byyear, weeklyperiods_byyear,
       dailyperiods, fullchronologyperiods,
       n_decision_days, n_represented_days, n_decision_hours,
       n_represented_hours

struct DispatchProblem{D<:DispatchSequence}

    model::JuMP.Model

    system::SystemParams

    dispatch::D

    function DispatchProblem(
        system::SystemParams, invyear::Int, periods::DispatchProxyMapping,
        optimizer; voll::Float64=NaN, unit_commitment::Bool=true
    )

        m = JuMP.direct_model(optimizer)

        dispatch = DispatchSequence(m, system, invyear, periods, voll,
                                    unit_commitment=unit_commitment)

        @objective(m, Min, annualization_factor(periods) * cost(dispatch))

        return new{typeof(dispatch)}(m, system, dispatch)

    end

end

function solve!(prob::DispatchProblem)

    flush(stdout)

    JuMP.optimize!(prob.model)

    JuMP.termination_status(prob.model) == JuMP.OPTIMAL ||
        @error "Problem did not solve to optimality"

end

cost(prob::DispatchProblem) =
    annualization_factor(prob.dispatch.time) * cost(prob.dispatch)

include("export.jl")

end
