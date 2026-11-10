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
       ..solve!, ..powerunits_MW, ..N_HOURS_IN_DAY, ..co2_offset_cost

import ..Data: dayidx

using ..Data

include("time.jl")
include("representative_periods.jl")
include("dispatch.jl")
include("sequencing.jl")

export DispatchProblem, DispatchSequence, DispatchDay, DispatchProxyMappings,
       singleperiod, seasonalperiods, monthlyperiods, weeklyperiods,
       seasonalperiods_byyear, monthlyperiods_byyear, weeklyperiods_byyear,
       dailyperiods, fullchronologyperiods,
       n_decision_days, n_represented_days, n_decision_hours,
       n_represented_hours, cost, co2, demand, co2_offset_cost,
       annualized_cost, annualized_co2, annualized_demand, annualized_co2_offset_cost

struct DispatchProblem{D<:DispatchSequence}

    model::JuMP.Model

    system::SystemParams
    invyear::Int

    dispatch::D

    function DispatchProblem(
        system::SystemParams, invyear::Int, periods::DispatchProxyMappings,
        optimizer;
        voll::Float64=NaN, # $/MWh
        co2_intensity_max::Float64=NaN, # kg/MWh
        co2_offset_price::Float64=999., # $/tonne
        unit_commitment::Bool=true
    )

       length(periods.mappings) == 1 ||
           error("DispatchProblem only supports solving a single " *
                 "DispatchSequence at a time. Formulate a separate " *
                 "DispatchProblem for each desired sequence.")

        # Convert to tonnes/powerunits_MWh
        co2_intensity_max *= powerunits_MW * 1e-3

        m = JuMP.direct_model(optimizer)

        dispatch = DispatchSequence(m, system, invyear, periods, voll=voll,
                                    co2_intensity_max=co2_intensity_max,
                                    co2_offset_price=co2_offset_price,
                                    unit_commitment=unit_commitment)

        @objective(m, Min, cost(dispatch))

        return new{typeof(dispatch)}(m, system, invyear, dispatch)

    end

end

function solve!(prob::DispatchProblem)

    flush(stdout)

    JuMP.optimize!(prob.model)

    JuMP.termination_status(prob.model) == JuMP.OPTIMAL ||
        @error "Problem did not solve to optimality"

end

cost(prob::DispatchProblem) = cost(prob.dispatch)

co2(prob::DispatchProblem) = co2(prob.dispatch)

co2_offset_cost(prob::DispatchProblem) = co2_offset_cost(prob.dispatch)

include("export.jl")

end
