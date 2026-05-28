module IterationModel

using C4.Data
using C4.AdequacyModel
using C4.DispatchModel
using C4.ExpansionModel

import ..store, ..powerunits_MW
<<<<<<< HEAD
import C4.ExpansionModel: RiskEstimateParams, RiskEstimatePeriodParams,
                          RiskEstimatePlaneParams,
                          CVaRRiskEstimateParams, CVaRRiskEstimatePeriodParams,
                          CVaRRiskEstimatePlaneParams,
                          nullcvar_estimator
=======
import C4.ExpansionModel: EUECuttingPlaneParams, EUECuttingPlaneRegionParams
>>>>>>> origin/gs/eue_surface_storage

import Dates: Date, now
import DBInterface
import DelimitedFiles: writedlm
import DuckDB
import JuMP: value
<<<<<<< HEAD
import PRAS: EUE, NEUE, val
import Statistics: mean, quantile
=======
>>>>>>> origin/gs/eue_surface_storage

export iterate_ra_cem

function iterate_ra_cem(
    sys::SystemParams, base_chronology::TimeProxyAssignment,
    max_neue::Float64, optimizer; neue_tol::Float64=.01,
    nsamples::Int=1000, skip_existing_stress_periods::Bool=false,
    timeout::Float64=Inf, first_feasible::Bool=true,
    aspp::Bool=true, endog_risk::Bool=true, outfile::String="",
    check_dispatch::Bool=false, check_dispatch_voll::Float64=NaN,
    risk_metric::Symbol=:eue, cvar_alpha::Float64=0.95)

    persist = length(outfile) > 0
    timeout += time()

    neue_factor = sum(sum(region.demand) for region in sys.regions) * 1e-6
    max_eue = max_neue * neue_factor

    n_regions = length(sys.regions)

    risk_metric in (:eue, :cvar) ||
        error("Unsupported risk metric $(risk_metric). Use :eue or :cvar")

    ram_start = now()
    ram = AdequacyProblem(sys, samples=nsamples)
    ram_result = solve(ram)
    ram_end = now()

    println("NEUE: ", neue(ram_result))
    println("LOLE: ", sum(ram_result.lolps))
    # println("LOLPs: ", ram_result.lolps)
    # println("EUEs: ", ram_result.eues)
    # println("Generation dEUE: ", ram_result.generation_dEUEs)
    # println("Storage Power dEUE: ", ram_result.storage_power_dEUEs)
    # println("Storage Energy dEUE: ", ram_result.storage_energy_dEUEs)
    #show_neues(ram_result)

    aug_start = now()

    chronology = if aspp
        add_stressperiod(sys, base_chronology, ram_result,
                         skip_existing=skip_existing_stress_periods)
    else
        base_chronology
    end

<<<<<<< HEAD
    risk_estimator = if risk_metric == :cvar
        nullcvar_estimator(chronology, n_regions, alpha=cvar_alpha)
    else
        nullestimator(chronology, n_regions)
    end
=======
>>>>>>> origin/gs/eue_surface_storage

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
    # Shouldn't we use initial RA results here? Right now they're only used for ASPP
    eue_estimator = EUECuttingPlaneParams[]
    n_iters = 0

    while (time() < timeout)

        n_iters += 1
        cem_start = now()

<<<<<<< HEAD
        cem = ExpansionProblem(sys, risk_estimator, max_eues, optimizer)
=======
        cem = ExpansionProblem(sys, chronology, eue_estimator, max_eue, optimizer)
>>>>>>> origin/gs/eue_surface_storage
        isnothing(prev_cem) || warmstart_builds!(cem, prev_cem)

        # println("Recurrences:")
        # for recc in cem.economicdispatch.recurrences
        #     println(recc.repetitions, " x ", recc.dispatch.period.name)
        # end

        solve!(cem)
        cem_end = now()

        ram_start = now()
        sys_built = SystemParams(cem)
        ram = AdequacyProblem(sys_built, samples=nsamples)
        ram_result = solve(ram)
        ram_end = now()

        println("NEUE: ", neue(ram_result))
        println("LOLE: ", sum(ram_result.lolps))
        # println("LOLPs: ", ram_result.lolps)
        # println("EUEs: ", ram_result.eues)
        # println("Generation dEUE: ", ram_result.generation_dEUEs)
        # println("Storage Power dEUE: ", ram_result.storage_power_dEUEs)
        # println("Storage Energy dEUE: ", ram_result.storage_energy_dEUEs)

        is_adequate = neue(ram_result) <= max_neue * (1 + neue_tol)

        aug_start = now()

        if aspp
            chronology = add_stressperiod(
                sys, chronology, ram_result,
                skip_existing=skip_existing_stress_periods)
        end

<<<<<<< HEAD
        risk_estimator = if endog_risk
            if risk_metric == :cvar
                CVaRRiskEstimateParams(chronology, adequacy_results, alpha=cvar_alpha)
            else
                RiskEstimateParams(chronology, adequacy_results)
            end
        else
            if risk_metric == :cvar
                nullcvar_estimator(chronology, n_regions, alpha=cvar_alpha)
            else
                nullestimator(chronology, n_regions)
            end
=======
        if endog_risk
            push!(eue_estimator, EUECuttingPlaneParams(cem, ram_result))
>>>>>>> origin/gs/eue_surface_storage
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

    return cem, ram_result, pcm

end

function CVaRRiskEstimateParams(
    time::TimeProxyAssignment,
    results::Vector{ExpansionAdequacyContext};
    alpha::Float64=0.95)

    period_params = [
        CVaRRiskEstimatePeriodParams(results, time, p, alpha=alpha)
        for p in eachindex(time.periods)
    ]

    return CVaRRiskEstimateParams(time, period_params, alpha=alpha)

end

function CVaRRiskEstimatePeriodParams(
    adequacycontexts::Vector{ExpansionAdequacyContext},
    time::TimeProxyAssignment,
    p::Int;
    alpha::Float64=0.95)

    R = size(first(adequacycontexts).available_capacity, 1)
    T = time.daylength
    J = length(adequacycontexts)

    representative_ts = time.periods[p].timesteps
    represented_ts = represented_timeslices(time, p)

    planes = Array{CVaRRiskEstimatePlaneParams,3}(undef, R, T, J)

    for (j, adequacycontext) in enumerate(adequacycontexts)

        shortfallsamples = adequacycontext.adequacy.shortfallsamples

        availablecapacity =
            adequacycontext.available_capacity[:, representative_ts]

        base_cvar = zeros(R,T)
        dCVaR = zeros(R,T)

        for t in 1:T

            represented_t = [ts[t] for ts in represented_ts]

            for r in 1:R
                period_samples = vec(sum(shortfallsamples.shortfall[r, represented_t, :], dims=1)) ./ powerunits_MW
                tail_mask = cvar_tail_mask(period_samples, alpha)

                base_cvar[r,t] = tail_masked_mean(period_samples, tail_mask)

                shortage_event_counts = vec(sum(shortfallsamples.shortfall[r, represented_t, :] .> 0, dims=1))
                dCVaR[r,t] = tail_masked_mean(shortage_event_counts, tail_mask)
            end

        end

        planes[:,:,j] .= CVaRRiskEstimatePlaneParams.(
            base_cvar, availablecapacity, dCVaR)

    end

    return planes

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

function add_stressperiod(
    sys::SystemParams, times::TimeProxyAssignment, adequacy::AdequacyResult;
    skip_existing::Bool=false
)

    # TODO: Could use gen_dEUEs now instead of EUE? Would capture storage
    #       charging opportunities
    days = reshape(adequacy.eues, times.daylength, :)
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

    base_eue = sum(adequacy.eues) / powerunits_MW

    regions = [EUECuttingPlaneRegionParams(builds, r, adequacy)
               for (r, builds) in enumerate(cem.builds.regions)]

    return EUECuttingPlaneParams(base_eue, regions)

end

end
