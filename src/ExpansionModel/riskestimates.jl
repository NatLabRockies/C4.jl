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

struct ReliabilityConstraints

    estimates::Vector{ReliabilityEstimate}

    region_eue::Vector{JuMP_ExpressionRef}
    region_eue_max::Vector{JuMP_LessThanConstraintRef}

    function ReliabilityConstraints(
        m::JuMP.Model, system::System, dispatches::Vector{<:ReliabilityDispatch},
        riskparams::RiskEstimateParams, eue_max::Vector{Float64}, seasonalconstraints::Bool)

        n_regions = length(system.regions)

        eue_estimates = [
            ReliabilityEstimate(m, system, dispatch, periodriskparams)
            for (dispatch, periodriskparams)
            in zip(dispatches, riskparams.periods)]

        if seasonalconstraints
            @info "Adding seasonal constraints to ReliabilityConstraints"
            n_periods = length(riskparams.periods)
            region_eue = Vector{JuMP_ExpressionRef}(undef, 0)
            region_eue_max = Vector{JuMP_LessThanConstraintRef}(undef, 0)

            for p in 1:n_periods, r in 1:n_regions
                expr = @expression(m, sum(eue_estimates[p].eue[r, :]))
                constraint = @constraint(m, expr <= eue_max[r])
                push!(region_eue, expr)
                push!(region_eue_max, constraint)
            end
            new(eue_estimates, region_eue, region_eue_max)
        else
            region_eue = @expression(m, [r in 1:n_regions],
                        sum(sum(estimate.eue[r, :]) for estimate in eue_estimates))
            
            region_eue_max = @constraint(m, [r in 1:n_regions],
                             region_eue[r, p] <= eue_max[r])
        end
        new(eue_estimates, region_eue, region_eue_max)
    end
end
