struct ThermalEUEReduction

    nameplate::Float64
    dEUE::Float64

    function ThermalEUEReduction(build::ThermalExpansion, gen_dEUEs::Vector{Float64})

        T = length(gen_dEUEs)
        nameplate = value(nameplatecapacity(build))
        dEUE = -sum(gen_dEUEs[t] * availability(build.params, t) for t in 1:T)

        return new(nameplate, dEUE)

    end

end

eue_adjustment(riskparams::ThermalEUEReduction, build::ThermalExpansion) =
    riskparams.dEUE * (nameplatecapacity(build) - riskparams.nameplate)

struct VariableSiteEUEReduction
    nameplate::Float64
    dEUE::Float64

    function VariableSiteEUEReduction(
        build::VariableSiteExpansion, gen_dEUEs::Vector{Float64})

        T = length(gen_dEUEs)
        nameplate = value(nameplatecapacity(build))
        dEUE = -sum(gen_dEUEs[t] * availability(build, t) for t in 1:T)

        return new(nameplate, dEUE)

    end

end

eue_adjustment(riskparams::VariableSiteEUEReduction, build::VariableSiteExpansion) =
    riskparams.dEUE * (nameplatecapacity(build) - riskparams.nameplate)

struct VariableEUEReduction

    sites::Vector{VariableSiteEUEReduction}

    function VariableEUEReduction(build::VariableExpansion, gen_dEUEs::Vector{Float64})

        sites = [VariableSiteEUEReduction(site, gen_dEUEs) for site in build.sites]

        return new(sites)

    end

end

eue_adjustment(riskparams::VariableEUEReduction, build::VariableExpansion) =
    sum(eue_adjustment(rp_site, b_site)
        for (rp_site, b_site) in zip(riskparams.sites, build.sites); init=0)

struct StorageEUEReduction

    nameplate_power::Float64
    dEUE_power::Float64

    nameplate_energy::Float64
    dEUE_energy::Float64

    function StorageEUEReduction(
        build::StorageExpansion, power_dEUE::Float64, energy_dEUE::Float64)

        return new(
            value(maxpower(build)), -power_dEUE,
            value(maxenergy(build)), -energy_dEUE)

    end

end

eue_adjustment(riskparams::StorageEUEReduction, build::StorageExpansion) =
        riskparams.dEUE_power * (build.power_new - riskparams.nameplate_power) +
        riskparams.dEUE_energy * (build.energy_new - riskparams.nameplate_energy)

struct EUECuttingPlaneRegionParams

    thermaltechs::Vector{ThermalEUEReduction}
    variabletechs::Vector{VariableEUEReduction}
    storagetechs::Vector{StorageEUEReduction}

    function EUECuttingPlaneRegionParams(builds::RegionExpansion, r::Int, adequacy::AdequacyResult)

        thermaltechs = [ThermalEUEReduction(build, adequacy.generation_dEUEs)
                        for build in builds.thermaltechs]

        variabletechs = [VariableEUEReduction(build, adequacy.generation_dEUEs)
                        for build in builds.variabletechs]

        storagetechs = [StorageEUEReduction(build, power_dEUE, energy_dEUE)
                        for (build, power_dEUE, energy_dEUE) in
                            zip(builds.storagetechs,
                                adequacy.storage_power_dEUEs,
                                adequacy.storage_energy_dEUEs)]

        return new(thermaltechs, variabletechs, storagetechs)

    end

end

function eue_adjustment(params::EUECuttingPlaneRegionParams, builds::RegionExpansion)


    thermal_adjustments = sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.thermaltechs, builds.thermaltechs);
        init=0
    )

    variable_adjustments = sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.variabletechs, builds.variabletechs);
        init=0
    )

    storage_adjustments = sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.storagetechs, builds.storagetechs);
        init=0
    )

    return thermal_adjustments + variable_adjustments + storage_adjustments

end

struct EUECuttingPlaneParams

    base_eue::Float64
    regions::Vector{EUECuttingPlaneRegionParams}

end

function cuttingplane(
    m::JuMP.Model, eue::JuMP.VariableRef, params::EUECuttingPlaneParams,
    builds::SystemExpansion)

    expansion_adjustments = sum(eue_adjustment(riskparams, builds)
        for (riskparams, builds) in zip(params.regions, builds.regions))

    plane = @constraint(m, eue >= params.base_eue + expansion_adjustments)
    JuMP.set_name(plane, "eue_cutting_plane")

    return plane

end

abstract type AbstractReliabilityConstraints end

struct ReliabilityConstraints <: AbstractReliabilityConstraints

    eue_params::Vector{EUECuttingPlaneParams}

    eue::JuMP.VariableRef
    eue_max::JuMP_LessThanConstraintRef
    eue_cuttingplanes::Vector{JuMP_GreaterThanConstraintRef}

    function ReliabilityConstraints(
        m::JuMP.Model, builds::SystemExpansion,
        eue_params::Vector{EUECuttingPlaneParams}, eue_max::Float64)

        eue = @variable(m, lower_bound = 0)
        JuMP.set_name(eue, "eue")

        eue_max = @constraint(m, eue <= eue_max)
        JuMP.set_name(eue_max, "eue_max")

        eue_cuttingplanes = [cuttingplane(m, eue, params, builds)
                             for params in eue_params]

        new(eue_params, eue, eue_max, eue_cuttingplanes)

    end

end

struct CVaRRiskEstimatePlaneParams

    base_cvar::Float64

    # (conditionally) Deterministic Capacity:
    # Available Variable Gen + Available Thermal Gen
    # + Storage Discharge - Storage Charge + Imports - Exports
    available_capacity::Float64

    # CVaR change associated with adding (conditionally) deterministic capacity
    dCVaR::Float64

end

function cvar_estimate(
    available_capacity::JuMP_ExpressionRef,
    riskparams::CVaRRiskEstimatePlaneParams)

    return riskparams.base_cvar - riskparams.dCVaR *
        (available_capacity - riskparams.available_capacity)

end

const CVaRRiskEstimatePeriodParams = Array{CVaRRiskEstimatePlaneParams,3} # RxTxJ

struct CVaRRiskEstimateParams

    times::TimeProxyAssignment
    periods::Vector{CVaRRiskEstimatePeriodParams}
    alpha::Float64

    function CVaRRiskEstimateParams(
        times::TimeProxyAssignment,
        estimators::Vector{CVaRRiskEstimatePeriodParams};
        alpha::Float64=0.95)

        length(times.periods) == length(estimators) ||
            error("Mismatched count of dispatch periods and CVaR estimators")

        0.0 < alpha < 1.0 ||
            error("CVaR alpha must be in (0, 1)")

        new(times, estimators, alpha)

    end

end

allperiods(riskparams::CVaRRiskEstimateParams) =
    [(period, riskparams.periods[i])
     for (i, period) in enumerate(riskparams.times.periods)]

function nullcvar_estimator(
    times::TimeProxyAssignment,
    n_regions::Int;
    alpha::Float64=0.95)

    n_periods = length(times.periods)
    n_timesteps = times.daylength

    nullperiod = Array{CVaRRiskEstimatePlaneParams,3}(
        undef, n_regions, n_timesteps, 0)

    return CVaRRiskEstimateParams(times, fill(nullperiod, n_periods), alpha=alpha)

end

struct CVaRReliabilityEstimate

    period::TimePeriod

    cvar::Matrix{JuMP.VariableRef}
    cvar_planes::Array{JuMP_GreaterThanConstraintRef,3}

    function CVaRReliabilityEstimate(
        m::JuMP.Model, system::System,
        dispatch::ReliabilityDispatch,
        riskparams::CVaRRiskEstimatePeriodParams)

        R, T, J = size(riskparams)
        period_name = dispatch.period.name

        cvar = @variable(m, [1:R, 1:T], lower_bound = 0)
        varnames!(cvar, "cvar[$(period_name)]", name.(system.regions), 1:T)

        cvar_planes = @constraint(m, [r in 1:R, t in 1:T, j in 1:J],
            cvar[r,t] >= cvar_estimate(
                dispatch.available_capacity[r,t], riskparams[r,t,j])
        )

        new(dispatch.period, cvar, cvar_planes)

    end

end

struct CVaRReliabilityConstraints <: AbstractReliabilityConstraints

    estimates::Vector{CVaRReliabilityEstimate}

    region_cvar::Vector{JuMP_ExpressionRef}
    region_cvar_max::Vector{JuMP_LessThanConstraintRef}

    function CVaRReliabilityConstraints(
        m::JuMP.Model, system::System, dispatches::Vector{<:ReliabilityDispatch},
        riskparams::CVaRRiskEstimateParams, cvar_max::Vector{Float64})

        n_regions = length(system.regions)

        cvar_estimates = [
            CVaRReliabilityEstimate(m, system, dispatch, periodriskparams)
            for (dispatch, periodriskparams)
            in zip(dispatches, riskparams.periods)]

        region_cvar = @expression(m, [r in 1:n_regions],
            sum(sum(estimate.cvar[r, :]) for estimate in cvar_estimates))

        region_cvar_max = @constraint(m, [r in 1:n_regions],
            region_cvar[r] <= cvar_max[r])

        new(cvar_estimates, region_cvar, region_cvar_max)

    end

end
