module ExpansionModel

import JuMP
import JuMP: @variable, @constraint, @expression, @objective, value

import  ..JuMP_GreaterThanConstraintRef, ..JuMP_LessThanConstraintRef,
        ..JuMP_ExpressionRef,
        ..Site, ..VariableSite,
        ..ThermalTechnology, ..VariableTechnology, ..StorageTechnology,
        ..Interface, ..Region, ..System, ..varnames!,
        ..nameplatecapacity, ..availablecapacity, ..availability, ..maxpower, ..maxenergy,
        ..roundtrip_efficiency, ..operating_cost,
        ..name, ..variabletechs, ..storagetechs, ..thermaltechs,
        ..sites, ..cost, ..cost_generation,
        ..region_from, ..region_to,
        ..demand, ..importinginterfaces, ..exportinginterfaces, ..solve!

import ..Data: ThermalExistingParams, ThermalCandidateParams,
               VariableExistingParams, VariableExistingSiteParams,
               VariableCandidateParams, VariableCandidateSiteParams,
               StorageExistingParams, StorageCandidateParams,
               SystemParams, RegionParams, InterfaceParams

using ..Data
using ..AdequacyModel
using ..DispatchModel

include("thermal.jl")
include("variable.jl")
include("storage.jl")

include("build.jl")

include("riskestimates.jl")

<<<<<<< HEAD
export ExpansionProblem, ExpansionAdequacyContext, warmstart_builds!, solve!,
    capex, opex, cost, lcoe, nullestimator,
    CVaRRiskEstimatePlaneParams, CVaRRiskEstimatePeriodParams,
    CVaRRiskEstimateParams, cvar_estimate, nullcvar_estimator
=======
export ExpansionProblem, EUECuttingPlaneParams, warmstart_builds!, solve!,
       capex, opex, cost, lcoe, nullestimator
>>>>>>> origin/gs/eue_surface_storage

# TODO: Simplify this now that it doesn't need to be abstracted
const ExpansionEconomicDispatch =
    DispatchSequence{EconomicDispatch{SystemExpansion,RegionExpansion,InterfaceExpansion}}

mutable struct ExpansionProblem

    model::JuMP.Model

    system::SystemParams

    builds::SystemExpansion

    economicdispatch::ExpansionEconomicDispatch

<<<<<<< HEAD
    reliabilitydispatch::ExpansionReliabilityDispatch
    reliabilityconstraints::AbstractReliabilityConstraints

    function ExpansionProblem(
        system::SystemParams,
        riskparams::Union{RiskEstimateParams,CVaRRiskEstimateParams},
        eue_max::Vector{Float64}, # in powerunits_MWh
=======
    reliabilityconstraints::ReliabilityConstraints

    function ExpansionProblem(
        system::SystemParams,
        chronology::TimeProxyAssignment,
        riskparams::Vector{EUECuttingPlaneParams},
        eue_max::Float64, # in powerunits_MWh
>>>>>>> origin/gs/eue_surface_storage
        optimizer)

        n_timesteps = length(system.timesteps)
        n_regions = length(system.regions)

        timestepcount(chronology) == n_timesteps ||
            error("Time period assignment is incompatible with system timesteps")

        m = JuMP.direct_model(optimizer)

        builds = SystemExpansion(
            [RegionExpansion(m, r) for r in system.regions],
            [InterfaceExpansion(m, i) for i in system.interfaces])

        economicdispatch = DispatchSequence(
            EconomicDispatch, m, builds, chronology)

<<<<<<< HEAD
        reliabilityconstraints = build_reliability_constraints(
            m, builds, reliabilitydispatch.dispatches, riskparams, eue_max)
=======
        reliabilityconstraints = ReliabilityConstraints(
            m, builds, riskparams, eue_max)
>>>>>>> origin/gs/eue_surface_storage

        opex_scalar = 8766 / n_timesteps

        @objective(m, Min, cost(builds) + opex_scalar * cost(economicdispatch))

        return new(m, system, builds, economicdispatch, reliabilityconstraints)

    end

end

build_reliability_constraints(
    m::JuMP.Model,
    system::System,
    dispatches::Vector{<:ReliabilityDispatch},
    riskparams::RiskEstimateParams,
    maxrisk::Vector{Float64}) =
    ReliabilityConstraints(m, system, dispatches, riskparams, maxrisk)

build_reliability_constraints(
    m::JuMP.Model,
    system::System,
    dispatches::Vector{<:ReliabilityDispatch},
    riskparams::CVaRRiskEstimateParams,
    maxrisk::Vector{Float64}) =
    CVaRReliabilityConstraints(m, system, dispatches, riskparams, maxrisk)

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
cost(prob::ExpansionProblem) = capex(prob) + opex(prob)

function lcoe(prob::ExpansionProblem)

    # Scale demand to an approximate annual value to compare to annualized costs
    demand_scaler = 8766 / length(prob.system.timesteps)

    # Note: total demand here is the full-chronology demand,
    #       not necessarily what economic dispatch sees
    demand = total_demand(prob.system) * powerunits_MW * demand_scaler

    return cost(prob) / demand

end

SystemParams(prob::ExpansionProblem) = SystemParams(
    prob.system.name, prob.system.timesteps,
    RegionParams.(prob.builds.regions), InterfaceParams.(prob.builds.interfaces)
)

function warmstart_builds!(prob::ExpansionProblem, prev_prob::ExpansionProblem)
    warmstart_builds!.(prob.builds.regions, prev_prob.builds.regions)
    warmstart_builds!.(prob.builds.interfaces, prev_prob.builds.interfaces)
    return
end


include("export.jl")

end
