module IterationModel

using C4.Data
using C4.AdequacyModel
using C4.DispatchModel
using C4.ExpansionModel

import ..store, ..powerunits_MW
import C4.ExpansionModel: EUECuttingPlaneParams, EUECuttingPlaneRegionParams

import Dates: Date, now
import DBInterface
import DelimitedFiles: writedlm
import DuckDB
import JuMP: value

export iterate_ra_cem

function iterate_ra_cem(
    sys::SystemParams, base_chronology::TimeProxyAssignment,
    max_neue::Union{Float64,Dict{String,Float64}}, optimizer;
    nsamples::Int=1000, skip_existing_stress_periods::Bool=false,
    timeout::Float64=Inf, first_feasible::Bool=true,
    aspp::Bool=true, endog_risk::Bool=true, outfile::String="",
    check_dispatch::Bool=false, check_dispatch_voll::Float64=NaN)

    seasonal = max_neue isa Dict{String,Float64}

    persist = length(outfile) > 0
    timeout += time()

    # annual_neue_factor converts NEUE (ppm) ↔ EUE (data units) for the non-seasonal case
    annual_neue_factor = sum(sum(region.demand) for region in sys.regions) * 1e-6

    # EUE limits used by the JuMP model (data units)
    max_eue = seasonal ? nothing : max_neue * annual_neue_factor

    # Seasonal: each season's EUE budget uses that season's own demand as denominator,
    # so the constraint means season_EUE / season_demand <= max_neue_ppm.
    # This matches the old implementation (max_eues_by_period[r,p] = max_neue * demand_share).
    season_neue_factors = if seasonal
        _T = base_chronology.daylength
        _N = length(first(sys.regions).demand)
        Dict(
            string(period.name) =>
                sum(
                    sum(region.demand[(d-1)*_T+h] for region in sys.regions)
                    for d in findall(isequal(s), base_chronology.days)
                    for h in 1:_T
                    if (d-1)*_T+h <= _N
                ) * 1e-6
            for (s, period) in enumerate(base_chronology.periods)
        )
    else
        nothing
    end

    period_max_eues = seasonal ? Dict(name => max_neue[name] * season_neue_factors[name]
                                      for name in keys(max_neue)) : nothing

    n_regions = length(sys.regions)

    ram_start = now()
    ram = AdequacyProblem(sys, samples=nsamples)
    ram_result = solve(ram)
    ram_end = now()

    println("NEUE: ", neue(ram_result))
    println("LOLE: ", sum(ram_result.lolps))

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
    # Non-seasonal: flat accumulator of cutting planes.
    # Seasonal: one accumulator per initial chronology season, keyed by period name.
    eue_estimator    = EUECuttingPlaneParams[]
    season_estimator = seasonal ? Dict{String,Vector{EUECuttingPlaneParams}}(
        string(period.name) => EUECuttingPlaneParams[]
        for period in base_chronology.periods) : nothing
    n_iters = 0

    while (time() < timeout)

        n_iters += 1
        cem_start = now()

        cem = if seasonal
            period_riskparams = [
                string(period.name) => season_estimator[string(period.name)]
                for period in base_chronology.periods
            ]
            ExpansionProblem(sys, chronology, period_riskparams, period_max_eues, optimizer)
        else
            ExpansionProblem(sys, chronology, eue_estimator, max_eue, optimizer)
        end
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

        println("NEUE: ", neue(ram_result))
        println("LOLE: ", sum(ram_result.lolps))

        is_adequate = if seasonal
            all(
                period_neue(ram_result, base_chronology, s,
                    season_neue_factors[string(base_chronology.periods[s].name)]) <=
                    max_neue[string(base_chronology.periods[s].name)]
                for s in eachindex(base_chronology.periods)
            )
        else
            neue(ram_result) <= max_neue
        end

        aug_start = now()

        if aspp
            chronology = add_stressperiod(
                sys, chronology, ram_result,
                skip_existing=skip_existing_stress_periods)
        end

        if endog_risk
            if seasonal
                for (sname, plane) in
                        seasonal_EUECuttingPlaneParams(cem, ram_result, base_chronology)
                    push!(season_estimator[sname], plane)
                end
            else
                push!(eue_estimator, EUECuttingPlaneParams(cem, ram_result))
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

    return cem, ram_result, pcm

end

function add_stressperiod(
    sys::SystemParams, times::TimeProxyAssignment, adequacy::AdequacyResult;
    skip_existing::Bool=false
)

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

# Build one EUECuttingPlaneParams per initial season from a single adequacy result.
# Returns a Vector{Pair{String,EUECuttingPlaneParams}} ordered by base_chronology.periods.
# Season membership is determined by base_chronology.days: the calendar days
# mapped to each initial period define which full-year timesteps belong to that season.
# lolps for non-season timesteps are zeroed so dEUE is season-specific.
function seasonal_EUECuttingPlaneParams(
    cem::ExpansionProblem,
    adequacy::AdequacyResult,
    base_chronology::TimeProxyAssignment)

    N      = length(adequacy.eues)
    T      = base_chronology.daylength

    [
        begin
            sname       = string(season_period.name)
            season_days = findall(isequal(s), base_chronology.days)

            # Season-masked gen_dEUEs: zero outside this season's calendar days
            gen_dEUEs_season = zeros(N)
            for d in season_days, h in 1:T
                t = (d - 1) * T + h
                t <= N && (gen_dEUEs_season[t] = adequacy.generation_dEUEs[t])
            end

            # Season-masked storage dEUEs: sum per-timestep duals over season only
            season_ts = [((d-1)*T+h) for d in season_days for h in 1:T
                         if (d-1)*T+h <= N]
            stor_power_dEUEs_season  = vec(sum(
                adequacy.storage_power_dEUEs_ts[season_ts,  :], dims=1))
            stor_energy_dEUEs_season = vec(sum(
                adequacy.storage_energy_dEUEs_ts[season_ts, :], dims=1))

            # Base EUE for this season (sum of shortfall over season timesteps)
            base_eue = sum(
                adequacy.eues[(d - 1) * T + h]
                for d in season_days for h in 1:T
                if (d - 1) * T + h <= N
            ) / powerunits_MW

            regions = [
                EUECuttingPlaneRegionParams(builds, r, adequacy, gen_dEUEs_season,
                    stor_power_dEUEs_season, stor_energy_dEUEs_season)
                for (r, builds) in enumerate(cem.builds.regions)
            ]

            sname => EUECuttingPlaneParams(base_eue, regions)
        end
        for (s, season_period) in enumerate(base_chronology.periods)
    ]

end

# Compute the NEUE attributable to a single initial chronology season (s index)
# from a full-year adequacy result.  Uses base_chronology.days to identify
# which calendar days belong to season s.
function period_neue(
    adequacy::AdequacyResult,
    base_chronology::TimeProxyAssignment,
    s::Int,
    annual_neue_factor::Float64)

    T           = base_chronology.daylength
    season_days = findall(isequal(s), base_chronology.days)
    N           = length(adequacy.eues)

    season_eue = sum(
        adequacy.eues[(d - 1) * T + h]
        for d in season_days for h in 1:T
        if (d - 1) * T + h <= N
    ) / powerunits_MW

    return season_eue / annual_neue_factor

end

end
