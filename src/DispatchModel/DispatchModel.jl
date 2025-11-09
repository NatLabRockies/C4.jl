module DispatchModel

import JuMP
import JuMP: @variable, @constraint, @expression, @objective, value

import IterTools: zip_longest

import ..ThermalTechnology, ..VariableTechnology, ..StorageTechnology,
       ..System,
       ..JuMP_ExpressionRef, ..JuMP_LessThanConstraintRef,
       ..JuMP_GreaterThanConstraintRef, ..JuMP_EqualToConstraintRef, ..varnames!,
       ..availablecapacity, ..nameplatecapacity, ..maxpower, ..maxenergy,
       ..roundtrip_efficiency, ..operating_cost, ..max_unit_ramp, ..num_units,
       ..unit_size, ..min_gen, ..min_uptime, ..min_downtime,
       ..name, ..cost, ..co2, ..cost_generation, ..cost_startup,
       ..co2_generation, ..co2_startup, ..demand,
       ..variabletechs, ..storagetechs, ..thermaltechs,
       ..solve!, ..powerunits_MW

using ..Data

include("dispatch.jl")
include("sequencing.jl")

export DispatchProblem, DispatchSequence

struct DispatchProblem{D<:DispatchSequence}

    model::JuMP.Model

    system::SystemParams

    dispatch::D

    function DispatchProblem(
        system::SystemParams, periods::TimeProxyAssignment,
        optimizer; voll::Float64=NaN
    )

        n_timesteps = length(system.timesteps)

        timestepcount(periods) == n_timesteps ||
            error("Period assignment is incompatible with system timesteps")

        m = JuMP.direct_model(optimizer)

        dispatch = DispatchSequence(m, system, periods, voll)

        opex_scalar = 8766 / n_timesteps
        @objective(m, Min, opex_scalar * cost(dispatch))

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
    8766 / length(prob.system.timesteps) * cost(prob.dispatch)

include("export.jl")

end
