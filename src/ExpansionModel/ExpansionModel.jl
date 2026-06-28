module ExpansionModel

import JuMP
import JuMP: @variable, @constraint, @expression, @objective,
             value, set_upper_bound

import  ..JuMP_GreaterThanConstraintRef, ..JuMP_LessThanConstraintRef,
        ..JuMP_ExpressionRef,
        ..DispatchableSite, ..DispatchableVariableSite,
        ..DispatchableThermalTech, ..DispatchableVariableTech, ..DispatchableStorageTech,
        ..DispatchableSystem, ..varnames!,
        ..nameplatecapacity, ..availablecapacity, ..availability, ..maxpower, ..maxenergy,
        ..roundtrip_efficiency, ..operating_cost,
        ..name, ..variabletechs, ..storagetechs, ..thermaltechs,
        ..sites, ..cost, ..co2,
        ..cost_generation, ..cost_startup, ..co2_generation, ..co2_startup,
        ..max_unit_ramp, ..num_units, ..unit_size, ..min_gen,
        ..min_uptime, ..min_downtime,
        ..demand, ..solve!, ..N_HOURS_IN_DAY, ..co2_offset_cost

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
       capex, opex, cost, lcoe, co2_offset_cost, emissions_intensity, nullestimator

mutable struct ExpansionProblem

    model::JuMP.Model

    system::SystemParams

    builds::SystemExpansion

    # Store one DispatchSequence per investment year
    dispatches::Vector{DispatchSequence{SystemExpansion}} # n_investment_years

    reliabilityconstraints::Vector{ReliabilityConstraints}

    function ExpansionProblem(
        system::SystemParams,
        chronologies::Vector{DispatchProxyMapping},
        riskparams::Vector{Vector{EUECuttingPlaneParams}},
        eue_max::Vector{Float64}, # in powerunits_MWh
        optimizer;
        co2_max::Vector{Float64}=Float64[], # in annual tonnes CO2
        co2_offset_price::Float64=NaN, # $/tonne CO2
        unit_commitment::Bool=true,
        discount_rate::Float64=0.
    )

       n_years_investment = n_investment_years(system.times)
       length(chronologies) == n_years_investment ||
            error("Nummber of time period dispatch proxy assignments does not match " *
                  "number of system investment years")

       length(eue_max) == n_years_investment ||
            error("Nummber of EUE caps provided does not match " *
                  "number of system investment years")

       iszero(length(co2_max)) || length(co2_max) == n_years_investment ||
            error("Nummber of emissions intensity caps provided does not match " *
                  "number of system investment years")

        n_hours_full = n_dispatch_hours(system.times)
        all(c -> n_represented_hours(c) == n_hours_full, chronologies) ||
            error("A time period dispatch proxy assignment is incompatible " *
                  "with the number of system dispatch timesteps")

        if iszero(length(co2_max))
            co2_max = fill(NaN, n_years_investment)
        end

        m = JuMP.direct_model(optimizer)

        builds = SystemExpansion(m, system)

        dispatches = [
            DispatchSequence(m, builds, i, chronology,
                             co2_max=co2_max[i],
                             co2_offset_price=co2_offset_price,
                             unit_commitment=unit_commitment)
            for (i, chronology) in enumerate(chronologies)]

        reliabilityconstraints = [
            ReliabilityConstraints(m, builds, i, riskparams[i], eue_max[i])
            for i in eachindex(chronologies)]

        @objective(m, Min,
            npv(cost, builds, system.times, discount_rate) +
            annualization_factor(system.times) *
                npv(cost, dispatches, system.times, discount_rate))

        return new(m, system, builds, dispatches, reliabilityconstraints)

    end

end

function SystemParams(prob::ExpansionProblem)

    params = prob.system
    build = prob.builds

    thermal_existing = vcat(
            ThermalExistingParams.(build.thermaltechs),
            params.thermaltechs_existing)

    variable_existing = vcat(
            VariableExistingParams.(build.variabletechs),
            params.variabletechs_existing)

    storage_existing = vcat(
            StorageExistingParams.(build.storagetechs),
            params.storagetechs_existing)

    return SystemParams(
        params.name, params.times, params.demand, params.fuels,
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

# TODO: Is it more useful to report these outcomes (especially relative ones
# like carbon intensity and LCOE) by investment year, rather than in aggregate?

# Capex is annualized, so scale opex to approximate an annual cost
# Note that opex includes any carbon offset costs
opex(prob::ExpansionProblem; discount_rate::Float64=0.) =
    annualization_factor(prob.system.times) *
    npv(cost, prob.dispatches, prob.system.times, discount_rate)

capex(prob::ExpansionProblem; discount_rate::Float64=0.) =
    npv(cost, prob.builds, prob.system.times, discount_rate)

# Capex is annualized, so scale carbon offset cost to approximate an annual cost
co2_offset_cost(prob::ExpansionProblem; discount_rate::Float64=0.) =
    annualization_factor(prob.system.times) *
    npv(co2_offset_cost, prob.dispatches, prob.system.times, discount_rate)

cost(prob::ExpansionProblem) = capex(prob) + opex(prob)

"""
CO2 emissions in annualized tonnes
"""
co2(prob::ExpansionProblem) =
    annualization_factor(prob.system.times) *
        npv(co2, prob.dispatches, prob.system.times, 0.0)

function lcoe(prob::ExpansionProblem)

    # Note: total demand used here is the full-chronology demand annualized,
    #       not necessarily what economic dispatch sees
    demand = npv(total_demand, prob.system, prob.system.times, 0.0) *
                    powerunits_MW * annualization_factor(prob.system.times)

    return cost(prob) / demand

end

"""
System emissions intensity in kg/MWh (g/kWh)
"""
function emissions_intensity(prob::ExpansionProblem)

    # Note: total demand used here is the full-chronology demand annualized,
    #       not necessarily what economic dispatch sees
    demand = npv(total_demand, prob.system, prob.system.times, 0.0) *
                    powerunits_MW * annualization_factor(prob.system.times)

    # Convert CO2 from tonnes to kg
    return co2(prob) * 1e3 / demand

end

function warmstart_builds!(prob::ExpansionProblem, prev_prob::ExpansionProblem)
    warmstart_builds!.(prob.builds.thermaltechs, prev_prob.builds.thermaltechs)
    warmstart_builds!.(prob.builds.variabletechs, prev_prob.builds.variabletechs)
    warmstart_builds!.(prob.builds.storagetechs, prev_prob.builds.storagetechs)
    return
end


include("export.jl")

end
