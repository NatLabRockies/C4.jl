module ExpansionModel

import JuMP
import JuMP: @variable, @constraint, @expression, @objective, value

import  ..JuMP_GreaterThanConstraintRef, ..JuMP_LessThanConstraintRef,
        ..JuMP_ExpressionRef,
        ..Site, ..VariableSite,
        ..ThermalTechnology, ..VariableTechnology, ..StorageTechnology,
        ..System, ..varnames!,
        ..nameplatecapacity, ..availablecapacity, ..availability, ..maxpower, ..maxenergy,
        ..roundtrip_efficiency, ..operating_cost,
        ..name, ..variabletechs, ..storagetechs, ..thermaltechs,
        ..sites, ..cost, ..co2,
        ..cost_generation, ..cost_startup, ..co2_generation, ..co2_startup,
        ..max_unit_ramp, ..num_units, ..unit_size, ..min_gen,
        ..min_uptime, ..min_downtime,
        ..demand, ..solve!

import ..Data: ThermalExistingParams, ThermalCandidateParams,
               VariableExistingParams, VariableExistingSiteParams,
               VariableCandidateParams, VariableCandidateSiteParams,
               StorageExistingParams, StorageCandidateParams, SystemParams

using ..Data
using ..AdequacyModel
using ..DispatchModel

include("thermal.jl")
include("variable.jl")
include("storage.jl")

include("build.jl")

include("riskestimates.jl")

export ExpansionProblem, EUECuttingPlaneParams, warmstart_builds!, solve!,
       capex, opex, carbon_offset_cost, cost, lcoe, emissions_intensity, nullestimator

mutable struct ExpansionProblem

    model::JuMP.Model

    system::SystemParams

    builds::SystemExpansion

    economicdispatch::DispatchSequence{SystemExpansion}

    reliabilityconstraints::ReliabilityConstraints

    carbon_offset_price::Float64
    carbon_offsets::Union{JuMP.VariableRef,Nothing} # in annual Megatonnes CO2
    co2_constraint::Union{JuMP_LessThanConstraintRef,Nothing}

    function ExpansionProblem(
        system::SystemParams,
        chronology::TimeProxyAssignment,
        riskparams::Vector{EUECuttingPlaneParams},
        eue_max::Float64, # in powerunits_MWh
        co2_max::Float64, # in annual Megatonnes CO2
        carbon_offset_price::Float64, # $/tonne CO2
        optimizer;
        unit_commitment::Bool=true
    )

        n_timesteps = length(system.timesteps)

        timestepcount(chronology) == n_timesteps ||
            error("Time period assignment is incompatible with system timesteps")

        m = JuMP.direct_model(optimizer)

        builds = SystemExpansion(m, system)

        economicdispatch = DispatchSequence(m, builds, chronology, unit_commitment=unit_commitment)

        reliabilityconstraints = ReliabilityConstraints(
            m, builds, riskparams, eue_max)

        if isnan(co2_max)
            carbon_offsets = co2_constraint = nothing
            carbon_offset_cost = 0
        else
            carbon_offsets = @variable(m, lower_bound=0)
            co2_constraint = @constraint(m,
                co2(economicdispatch) - carbon_offsets <= co2_max)
            # convert $/tonne to $/Megatonne
            carbon_offset_cost = (carbon_offset_price * 1e6) * carbon_offsets
        end

        annualization_factor = 8766 / n_timesteps

        @objective(m, Min,
            cost(builds) + annualization_factor *
                (cost(economicdispatch) + carbon_offset_cost)
        )

        return new(m, system, builds, economicdispatch, reliabilityconstraints,
                   carbon_offset_price, carbon_offsets, co2_constraint)

    end

end

function SystemParams(prob::ExpansionProblem)

    params = prob.system
    build = prob.builds

    thermal_existing = vcat(
            [ThermalExistingParams(tech)
             for tech in build.thermaltechs
             if value(nameplatecapacity(tech)) > 0],
            params.thermaltechs_existing)

    variable_existing = vcat(
            [VariableExistingParams(tech)
             for tech in build.variabletechs
             if value(nameplatecapacity(tech)) > 0],
            params.variabletechs_existing)

    # We leave in all storage resources (whether built or not)
    # in order to simplify extracting marginal EUE reductions from
    # PRAS results later
    storage_existing = vcat(
            [StorageExistingParams(tech) for tech in build.storagetechs],
            params.storagetechs_existing)

    return SystemParams(
        params.name, params.timesteps, params.demand, params.fuels,
        thermal_existing,
        ThermalCandidateParams.(build.thermaltechs),
        variable_existing,
        VariableCandidateParams.(build.variabletechs),
        storage_existing,
        StorageCandidateParams.(build.storagetechs))

end

function solve!(prob::ExpansionProblem)

    flush(stdout)

    JuMP.optimize!(prob.model)

    JuMP.termination_status(prob.model) == JuMP.OPTIMAL ||
        @error "Problem did not solve to optimality"

end

# Capex is annualized, so scale opex to approximate an annual cost
opex(prob::ExpansionProblem) =
    8766 / length(prob.system.timesteps) * cost(prob.economicdispatch)

capex(prob::ExpansionProblem) = cost(prob.builds)

# Capex is annualized, so scale carbon offset cost to approximate an annual cost
function carbon_offset_cost(prob::ExpansionProblem)

    if isnothing(prob.carbon_offsets)
        0
    else
        annualization_factor = 8766 / length(prob.system.timesteps)
        annualization_factor * (prob.carbon_offset_price * 1e6) * prob.carbon_offsets
    end

end

cost(prob::ExpansionProblem) = capex(prob) + opex(prob) + carbon_offset_cost(prob)

"""
CO2 emissions in annualized Megatonnes
"""
co2(prob::ExpansionProblem) =
    8766 / length(prob.system.timesteps) * co2(prob.economicdispatch)

function lcoe(prob::ExpansionProblem)

    # Scale demand to an approximate annual value to compare to annualized costs
    demand_scaler = 8766 / length(prob.system.timesteps)

    # Note: total demand here is the full-chronology demand,
    #       not necessarily what economic dispatch sees
    demand = total_demand(prob.system) * powerunits_MW * demand_scaler

    return cost(prob) / demand

end

"""
System emissions intensity in kg/MWh (g/kWh)
"""
emissions_intensity(prob::ExpansionProblem) =
    co2(prob.economicdispatch) / (total_demand(prob.system) * powerunits_MW) * 1e9

function warmstart_builds!(prob::ExpansionProblem, prev_prob::ExpansionProblem)
    warmstart_builds!.(prob.builds.thermaltechs, prev_prob.builds.thermaltechs)
    warmstart_builds!.(prob.builds.variabletechs, prev_prob.builds.variabletechs)
    warmstart_builds!.(prob.builds.storagetechs, prev_prob.builds.storagetechs)
    return
end


include("export.jl")

end
