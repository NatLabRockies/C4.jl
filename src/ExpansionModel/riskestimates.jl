struct RiskEstimatePlaneParams

    base_eue::Float64

    # (conditionally) Deterministic Capacity:
    # Available Variable Gen + Available Thermal Gen
    # + Storage Discharge - Storage Charge + Imports - Exports
    available_capacity::Float64

    # EUE change associated with adding (conditionally) deterministic capacity
    dEUE::Float64

end

function eue_estimate(
    available_capacity::JuMP_ExpressionRef,
    riskparams::RiskEstimatePlaneParams)

    return riskparams.base_eue - riskparams.dEUE *
        (available_capacity - riskparams.available_capacity)

end

const RiskEstimatePeriodParams = Array{RiskEstimatePlaneParams,3} # RxTxJ

struct RiskEstimateParams

    times::TimeProxyAssignment
    periods::Vector{RiskEstimatePeriodParams}

    function RiskEstimateParams(
        times::TimeProxyAssignment, estimators::Vector{RiskEstimatePeriodParams}
    )

        length(times.periods) == length(estimators) ||
            error("Mismatched count of dispatch periods and EUE estimators")

        new(times, estimators)

    end

end

# TODO: Could implement iterator interface here for slightly nicer usage
allperiods(riskparams::RiskEstimateParams) =
    [(period, riskparams.periods[i])
     for (i, period) in enumerate(riskparams.times.periods)]

function nullestimator(times::TimeProxyAssignment, n_regions::Int)

    n_periods = length(times.periods)
    n_timesteps = times.daylength

    nullperiod = Array{RiskEstimatePlaneParams,3}(undef, n_regions, n_timesteps, 0)

    return RiskEstimateParams(times, fill(nullperiod, n_periods))

end

struct ReliabilityEstimate

    period::TimePeriod

    eue::Matrix{JuMP.VariableRef}
    eue_planes::Array{JuMP_GreaterThanConstraintRef,3}

    function ReliabilityEstimate(
        m::JuMP.Model, system::System,
        dispatch::ReliabilityDispatch,
        riskparams::RiskEstimatePeriodParams)

        R, T, J = size(riskparams)
        period_name = dispatch.period.name

        eue = @variable(m, [1:R, 1:T], lower_bound = 0)
        varnames!(eue, "eue[$(period_name)]", name.(system.regions), 1:T)

        eue_planes = @constraint(m, [r in 1:R, t in 1:T, j in 1:J],
            eue[r,t] >= eue_estimate(
                dispatch.available_capacity[r,t], riskparams[r,t,j])
        )

        new(dispatch.period, eue, eue_planes)

    end

end

abstract type AbstractReliabilityConstraints end

struct ReliabilityConstraints <: AbstractReliabilityConstraints

    estimates::Vector{ReliabilityEstimate}

    region_eue::Vector{JuMP_ExpressionRef}
    region_eue_max::Vector{JuMP_LessThanConstraintRef}

    function ReliabilityConstraints(
        m::JuMP.Model, system::System, dispatches::Vector{<:ReliabilityDispatch},
        riskparams::RiskEstimateParams, eue_max::Vector{Float64})

        n_regions = length(system.regions)

        eue_estimates = [
            ReliabilityEstimate(m, system, dispatch, periodriskparams)
            for (dispatch, periodriskparams)
            in zip(dispatches, riskparams.periods)]

        region_eue = @expression(m, [r in 1:n_regions],
            sum(sum(estimate.eue[r, :]) for estimate in eue_estimates))

        region_eue_max = @constraint(m, [r in 1:n_regions],
            region_eue[r] <= eue_max[r])

        new(eue_estimates, region_eue, region_eue_max)

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
