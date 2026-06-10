module IterationModel

using C4.Data
using C4.AdequacyModel
using C4.DispatchModel
using C4.ExpansionModel

import ..store, ..powerunits_MW
import C4.ExpansionModel: EUECuttingPlaneParams, EUECuttingPlaneRegionParams,
                          CVaRCuttingPlaneParams, CVaRCuttingPlaneRegionParams

import Dates: Date, now
import DBInterface
import DelimitedFiles: writedlm
import DuckDB
import JuMP: value
import Statistics: mean, quantile

export iterate_ra_cem

function iterate_ra_cem(
    sys::SystemParams, base_chronology::TimeProxyAssignment,
    max_neue::Float64, optimizer; neue_tol::Float64=.01,
    nsamples::Int=1000, skip_existing_stress_periods::Bool=false,
    timeout::Float64=Inf, first_feasible::Bool=true,
    aspp::Bool=true, endog_risk::Bool=true, outfile::String="",
    check_dispatch::Bool=false, check_dispatch_voll::Float64=NaN,
    risk_metric::Symbol=:eue, cvar_alpha::Float64=0.95, max_ncvar::Float64=NaN)

    persist = length(outfile) > 0
    timeout += time()

    neue_factor = sum(sum(region.demand) for region in sys.regions) * 1e-6
    max_eue = max_neue * neue_factor

    n_regions = length(sys.regions)

    risk_metric in (:eue, :cvar) ||
        error("Unsupported risk metric $(risk_metric). Use :eue or :cvar")

    risk_metric == :cvar && isnan(max_ncvar) &&
        error("max_ncvar must be provided when risk_metric=:cvar")

    # CVaR uses the same annual normalization as EUE (MWh/year per ppm)
    max_cvar = risk_metric == :cvar ? max_ncvar * neue_factor : NaN

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
    cvar_estimator = CVaRCuttingPlaneParams[]
    n_iters = 0

    while (time() < timeout)

        n_iters += 1
        cem_start = now()

        cem = if risk_metric == :cvar
            ExpansionProblem(sys, chronology, cvar_estimator, max_cvar, optimizer)
        else
            ExpansionProblem(sys, chronology, eue_estimator, max_eue, optimizer)
        end
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

        if endog_risk
            if risk_metric == :eue
                push!(eue_estimator, EUECuttingPlaneParams(cem, ram_result))
            elseif risk_metric == :cvar
                push!(cvar_estimator,
                    CVaRCuttingPlaneParams(cem, ram_result, cvar_alpha))
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

    persist && DBInterface.close!(con)
    return cem, ram_result, pcm

end

function CVaRCuttingPlaneParams(
    cem::ExpansionProblem,
    adequacy::AdequacyResult,
    alpha::Float64)

    # shortfall_samples is n_timesteps × n_samples (in internal power units)
    shortfall_samples = adequacy.shortfall_samples ./ powerunits_MW  # MWh

    # Total EUE per sample across all timesteps
    total_shortfall_samples = vec(sum(shortfall_samples, dims=1))  # n_samples

    # Tail: worst α-fraction of samples by total EUE
    tail = cvar_tail_mask(total_shortfall_samples, alpha)

    base_cvar = tail_masked_mean(total_shortfall_samples, tail)

    # storage_power_samples / storage_energy_samples: n_storages × n_samples
    # (already in internal power units — divided here to match shortfall units)
    stor_power_samples = adequacy.storage_power_samples ./ powerunits_MW
    stor_energy_samples = adequacy.storage_energy_samples ./ powerunits_MW

    regions = [
        CVaRCuttingPlaneRegionParams(
            builds, shortfall_samples, tail,
            stor_power_samples, stor_energy_samples)
        for builds in cem.builds.regions
    ]

    return CVaRCuttingPlaneParams(base_cvar, regions)

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
