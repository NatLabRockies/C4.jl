module IterationModel

using C4.Data
using C4.AdequacyModel
using C4.DispatchModel
using C4.ExpansionModel

import ..store, ..powerunits_MW
import C4.ExpansionModel: EUECuttingPlaneParams, EUECuttingPlaneRegionParams,
                          CVaRCuttingPlaneParams, CVaRCuttingPlaneRegionParams,
                          nullestimator, nullcvar_estimator

import Dates: Date, now
import DBInterface
import DelimitedFiles: writedlm
import DuckDB
import JuMP: value
import PRASCore: EUE, NEUE, val
import Statistics: mean, quantile

export iterate_ra_cem

function iterate_ra_cem(
    sys::SystemParams, base_chronology::TimeProxyAssignment,
    max_neue::Float64, optimizer;
    nsamples::Int=1000, skip_existing_stress_periods::Bool=false,
    timeout::Float64=Inf, first_feasible::Bool=true,
    aspp::Bool=true, endog_risk::Bool=true, outfile::String="",
    check_dispatch::Bool=false, check_dispatch_voll::Float64=NaN,
    risk_metric::Symbol=:eue, cvar_alpha::Float64=0.95,
    max_ncvar::Union{Nothing,Float64}=nothing)

    persist = length(outfile) > 0
    timeout += time()

    neue_factor = sum(sum(region.demand) for region in sys.regions) * 1e-6
    max_eue = max_neue * neue_factor
    max_cvar = isnothing(max_ncvar) ? nothing : max_ncvar * neue_factor

    risk_metric in (:eue, :cvar) ||
        error("Unsupported risk metric $(risk_metric). Use :eue or :cvar")

    risk_cap = if risk_metric == :cvar
        isnothing(max_cvar) &&
            error("CVaR runs require an explicit max_ncvar target; no implicit reuse of max_neue is allowed")
        max_cvar
    else
        max_eue
    end

    ram_start = now()
    ram = AdequacyProblem(sys, samples=nsamples)
    ram_result = solve(ram)
    ram_end = now()

    show_neues(ram_result)

    aug_start = now()

    chronology = if aspp
        add_stressperiod(sys, base_chronology, ram_result,
                         skip_existing=skip_existing_stress_periods)
    else
        base_chronology
    end


    aug_end = now()

    if persist
        store_start = now()
        con = DBInterface.connect(DuckDB.DB, outfile)
        store(con, sys)
        store_iteration(con, 0)
        store_iteration_step(con, 0, "adequacy", ram_start => ram_end)
        store(con, 0, ram_result)
        store_iteration_step(con, 0, "augmentation", aug_start => aug_end)
        store_end = now()
        store_iteration_step(con, 0, "persistence", store_start => store_end)
    end

    sys_built = nothing
    cem = nothing
    prev_cem = nothing
    risk_estimator = if risk_metric == :cvar
        nullcvar_estimator()
    else
        nullestimator()
    end
    n_iters = 0

    while (time() < timeout)

        n_iters += 1
        cem_start = now()

        cem = ExpansionProblem(sys, chronology, risk_estimator, risk_cap, optimizer)
        isnothing(prev_cem) || warmstart_builds!(cem, prev_cem)

        println("Recurrences:")
        for recc in cem.economicdispatch.recurrences
            println(recc.repetitions, " x ", recc.dispatch.period.name)
        end

        solve!(cem)
        cem_end = now()

        ram_start = now()
        sys_built = SystemParams(cem)
        ram = AdequacyProblem(sys_built, samples=nsamples)
        ram_result = solve(ram)
        ram_end = now()

        show_neues(ram_result)

        risk_value = if risk_metric == :cvar
            system_cvar(ram_result, cvar_alpha)
        else
            val(EUE(ram_result.shortfalls)) / powerunits_MW
        end
        is_adequate = risk_value <= risk_cap

        aug_start = now()

        if aspp
            chronology = add_stressperiod(
                sys, chronology, ram_result,
                skip_existing=skip_existing_stress_periods)
        end

        if endog_risk
            if risk_metric == :cvar
                push!(risk_estimator, CVaRCuttingPlaneParams(cem, ram_result, alpha=cvar_alpha))
            else
                push!(risk_estimator, EUECuttingPlaneParams(cem, ram_result))
            end
        end

        aug_end = now()

        if persist
            store_start = now()
            store_iteration(con, n_iters)
            store_iteration_step(con, n_iters, "expansion", cem_start => cem_end)
            store_iteration_step(con, n_iters, "adequacy", ram_start => ram_end)
            store_iteration_step(con, n_iters, "augmentation", aug_start => aug_end)
            store(con, n_iters, cem.builds)
            store(con, n_iters, cem.economicdispatch)
            store(con, n_iters, ram_result)
            DBInterface.execute(con, "CHECKPOINT")
            store_end = now()
            store_iteration_step(con, n_iters, "persistence", store_start => store_end)
            DBInterface.execute(con, "CHECKPOINT")
        end

        prev_cem = cem

        first_feasible && is_adequate && break

        aspp || endog_risk || break

    end

    pcm = nothing

    if (aspp || endog_risk) && check_dispatch

        pcm_start = now()
        n_iters += 1
        fullchrono = fullchronologyperiods(sys_built, daylength=base_chronology.daylength)
        pcm = DispatchProblem(sys_built, EconomicDispatch, fullchrono,
                              optimizer, check_dispatch_voll)
        solve!(pcm)
        pcm_end = now()

        if persist
            store_iteration(con, n_iters)
            store_iteration_step(con, n_iters, "dispatch", pcm_start => pcm_end)
            store(con, n_iters, pcm.dispatch)
        end

    end

    return cem, ram, pcm

end

function add_stressperiod(
    sys::SystemParams, times::TimeProxyAssignment, adequacy::AdequacyResult;
    skip_existing::Bool=false
)

    eues = sum(adequacy.shortfalls.shortfall_mean, dims=1)
    days = reshape(eues, times.daylength, :)
    days = vec(sum(days, dims=1))
    og_new_day = argmax(days)

    new_day = og_new_day
    new_day_first_hour = (new_day - 1) * times.daylength + 1

    while already_included(new_day_first_hour, times.periods)

        skip_existing && return times

        new_day = new_day > 1 ? new_day - 1 : length(days)
        new_day_first_hour = (new_day - 1) * times.daylength + 1

        if new_day == og_new_day
            @warn("No unmodeled stress periods left to add")
            return times
        end

    end

    ts = new_day_first_hour:(new_day_first_hour+times.daylength-1)
    name = string(Date(sys.timesteps[new_day_first_hour]))
    new_period = TimePeriod(ts, name)
    println("Adding period: $name")

    new_periods = [times.periods; new_period]

    new_days = copy(times.days)
    new_days[new_day] = length(new_periods)

    return TimeProxyAssignment(new_periods, new_days)

end

already_included(hour::Int, periods::Vector{TimePeriod}) =
    any(p -> in(hour, p.timesteps), periods)

function represented_timeslices(time::TimeProxyAssignment, p::Int)
    T = time.daylength
    return [((d-1)*T+1):(d*T) for d in findall(isequal(p), time.days)]
end

function EUECuttingPlaneParams(cem::ExpansionProblem, adequacy::AdequacyResult)

    base_eue = val(EUE(adequacy.shortfalls)) / powerunits_MW

    regions = [EUECuttingPlaneRegionParams(builds, r, adequacy)
               for (r, builds) in enumerate(cem.builds.regions)]

    return EUECuttingPlaneParams(base_eue, regions)

end

function CVaRCuttingPlaneParams(
    cem::ExpansionProblem,
    adequacy::AdequacyResult;
    alpha::Float64=0.95)

    tail_shortfall_samples =
        dropdims(sum(adequacy.shortfallsamples.shortfall, dims=1), dims=1) ./ powerunits_MW
    total_shortfall_samples = vec(sum(tail_shortfall_samples, dims=1))
    tail = cvar_tail_mask(total_shortfall_samples, alpha)
    stor_dCVaRs = tail_storage_marginals(adequacy.marginal_storage_samples, tail)
    base_cvar = tail_masked_mean(total_shortfall_samples, tail)

    regions = [CVaRCuttingPlaneRegionParams(builds, r, adequacy, tail_shortfall_samples, tail, stor_dCVaRs)
               for (r, builds) in enumerate(cem.builds.regions)]

    return CVaRCuttingPlaneParams(base_cvar, alpha, regions)

end

function system_cvar(adequacy::AdequacyResult, alpha::Float64)
    samples = vec(sum(adequacy.shortfallsamples.shortfall, dims=(1, 2))) ./ powerunits_MW
    tail = cvar_tail_mask(samples, alpha)
    return tail_masked_mean(samples, tail)
end

function cvar_tail_mask(samples::AbstractVector{<:Real}, alpha::Float64)
    isempty(samples) && return falses(0)
    var_alpha = quantile(samples, alpha)
    return samples .>= var_alpha
end

function tail_masked_mean(
    values::AbstractVector{<:Real},
    mask::AbstractVector{Bool})

    isempty(values) && return 0.0
    @assert length(values) == length(mask)

    tail_values = values[mask]
    isempty(tail_values) && return 0.0

    return mean(tail_values)

end

end
