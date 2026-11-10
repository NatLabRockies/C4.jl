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
        ..sites, ..cost, ..cost_fom, ..co2,
        ..cost_generation, ..cost_startup, ..co2_generation, ..co2_startup,
        ..max_unit_ramp, ..num_units, ..unit_size, ..min_gen,
        ..min_uptime, ..min_downtime,
        ..demand, ..solve!, ..N_HOURS_IN_DAY, ..co2_offset_cost

import ..Data: ThermalExistingParams, ThermalCandidateParams,
               VariableExistingParams, VariableExistingSiteParams,
               VariableCandidateParams, VariableCandidateSiteParams,
               StorageExistingParams, StorageCandidateParams, SystemParams,
               cost_capex, cost_capex_power, cost_capex_energy

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
        chronologies::Vector{DispatchProxyMappings},
        riskparams::Vector{Vector{EUECuttingPlaneParams}},
        eue_max::Vector{Float64}, # annualized powerunits_MWh
        optimizer;
        co2_intensity_max::Vector{Float64}=Float64[], # kg/MWh
        co2_offset_price::Float64=NaN, # $/tonne CO2
        cem_voll::Float64=NaN, # $/MWh, NaN = hard power balance (no slack)
        unit_commitment::Bool=true,
        wacc::Float64=0.,
        npv_year::Int=Int(first(system.times.investment_years))
    )

       n_years_investment = n_investment_years(system.times)
       length(chronologies) == n_years_investment ||
            error("Nummber of time period dispatch proxy assignments does not match " *
                  "number of system investment years")

       length(eue_max) == n_years_investment ||
            error("Nummber of EUE caps provided does not match " *
                  "number of system investment years")

       iszero(length(co2_intensity_max)) ||
       length(co2_intensity_max) == n_years_investment ||
            error("Nummber of emissions intensity caps provided does not match " *
                  "number of system investment years")

        n_hours_full = n_dispatch_hours(system.times)
        all(c -> sum(n_represented_hours(c)) == n_hours_full, chronologies) ||
            error("A time period dispatch proxy assignment is incompatible " *
                  "with the number of system dispatch timesteps")

        if iszero(length(co2_intensity_max))
            co2_intensity_max = fill(NaN, n_years_investment)
        end

        m = JuMP.direct_model(optimizer)

        builds = SystemExpansion(m, system)

        dispatches = [
            DispatchSequence(m, builds, i, chronology,
                             voll=cem_voll,
                             # convert from kg/MWh to tonnes/powerunits_MWh
                             co2_intensity_max=co2_intensity_max[i] * powerunits_MW * 1e-3,
                             co2_offset_price=co2_offset_price,
                             unit_commitment=unit_commitment)
            for (i, chronology) in enumerate(chronologies)]

        reliabilityconstraints = [
            ReliabilityConstraints(m, builds, i, riskparams[i], eue_max[i])
            for i in eachindex(chronologies)]

        @objective(m, Min,
            npv_capex(builds, system.times, wacc=wacc, npv_year=npv_year) +
            npv_yearly_recurring(annualized_cost, dispatches, system.times,
                                 discount_rate=wacc, npv_year=npv_year) +
            npv_yearly_recurring(cost_fom, builds, system.times,
                                 discount_rate=wacc, npv_year=npv_year)
            )

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

    status = JuMP.termination_status(prob.model)
    status == JuMP.OPTIMAL ||
        error("CEM did not solve to optimality (status: $status). " *
              "Primal status: $(JuMP.primal_status(prob.model)), " *
              "Dual status: $(JuMP.dual_status(prob.model))")

end

# Note that opex includes FO&M and any carbon offset costs
opex(prob::ExpansionProblem; discount_rate::Float64=0., npv_year::Int=0) =
    npv_yearly_recurring(annualized_cost, prob.dispatches, prob.system.times,
                         discount_rate=discount_rate, npv_year=npv_year) +
    npv_yearly_recurring(cost_fom, prob.builds, prob.system.times,
                         discount_rate=discount_rate, npv_year=npv_year)

capex(prob::ExpansionProblem; wacc::Float64=0., npv_year::Int=0) =
    npv_capex(prob.builds, prob.system.times, wacc=wacc, npv_year=npv_year)

co2_offset_cost(
    prob::ExpansionProblem; discount_rate::Float64=0., npv_year::Int=0) =
    npv_yearly_recurring(annualized_co2_offset_cost, prob.dispatches,
                        prob.system.times,
                        discount_rate=discount_rate, npv_year=npv_year)

cost(prob::ExpansionProblem) = capex(prob) + opex(prob)

"""
Cumulative annualized CO2 emissions in tonnes
"""
co2(prob::ExpansionProblem) =
        npv_yearly_recurring(annualized_co2, prob.dispatches, prob.system.times)

function lcoe(prob::ExpansionProblem)

    demand = npv_yearly_recurring(annualized_demand, prob.dispatches, prob.system.times) *
                    powerunits_MW

    return cost(prob) / demand

end

# TODO: Report by investment year instead / as well?
"""
System emissions intensity in kg/MWh (g/kWh)
"""
function emissions_intensity(prob::ExpansionProblem)

    demand = npv_yearly_recurring(annualized_demand, prob.dispatches, prob.system.times) *
                    powerunits_MW

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
