module IterationModel

using C4.Data
using C4.AdequacyModel
using C4.DispatchModel
using C4.ExpansionModel

import ..store, ..powerunits_MW
import C4.ExpansionModel: EUECuttingPlaneParams

import Dates: Date, now
import DBInterface
import DelimitedFiles: writedlm
import DuckDB
import JuMP: value

export iterate_ra_cem

function iterate_ra_cem(
    sys::SystemParams, base_chronologies::Vector{DispatchProxyMapping},
    max_neue::Float64, optimizer; neue_tol::Float64=.001,
    nsamples::Int=1000, skip_existing_stress_periods::Bool=false,
    max_co2_intensity::Float64=NaN, # kg/MWh
    co2_offset_price::Float64=9999., # $/tonne CO2
    timeout::Float64=Inf, first_feasible::Bool=true,
    aspp::Bool=true, endog_risk::Bool=true, outfile::String="",
    check_dispatch::Bool=false, check_dispatch_voll::Real=NaN,
    unit_commitment::Bool=true)

    persist = length(outfile) > 0
    timeout += time()

    demands = [total_demand(sys, i) for i in eachindex(base_chronologies)]

    max_eues = max_neue .* demands .* 1e-6
    max_co2s = max_co2_intensity .* (demands .* powerunits_MW) .* 1e-3 # in tonnes

    ram_start = now()
    ram = AdequacyProblem(sys, samples=nsamples)
    ram_result = solve(ram)
    ram_end = now()

    println("NEUEs: ", neues(ram_result),
            "\tLOLEs: ", vec(sum(ram_result.lolps, dims=(1,2))))

    aug_start = now()

    chronologies = if aspp
        [add_stressperiod(sys, invyear, chrono, ram_result,
                          skip_existing=skip_existing_stress_periods)
         for (invyear, chrono) in enumerate(base_chronologies)]
    else
        base_chronologies
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
    n_iters = 0

    # Shouldn't we use initial RA results here? Right now they're only used for ASPP
    eue_estimator = [EUECuttingPlaneParams[] for i in eachindex(base_chronologies)]

    while (time() < timeout)

        n_iters += 1
        cem_start = now()

        cem = ExpansionProblem(sys, chronologies, eue_estimator, max_eues,
                               optimizer,
                               co2_max=max_co2s, co2_offset_price=co2_offset_price,
                               unit_commitment=unit_commitment)

        isnothing(prev_cem) || warmstart_builds!(cem, prev_cem)

        # println("Recurrences:")
        # for recc in cem.dispatch.recurrences
        #     println(recc.repetitions, " x ", recc.dispatch.period.name)
        # end

        solve!(cem)
        cem_end = now()

        ram_start = now()
        sys_built = SystemParams(cem)
        ram = AdequacyProblem(sys_built, samples=nsamples)
        ram_result = solve(ram)
        ram_end = now()

        println("NEUEs: ", neues(ram_result),
                "\tLOLEs: ", vec(sum(ram_result.lolps, dims=(1,2))))

        is_adequate = all(
            neue(ram_result, i) <= max_neue * (1 + neue_tol)
            for i in eachindex(base_chronologies))

        aug_start = now()

        if aspp
            chronologies = [
                add_stressperiod(sys, invyear, chrono, ram_result,
                                 skip_existing=skip_existing_stress_periods)
                 for (invyear, chrono) in enumerate(base_chronologies)]
        end

        if endog_risk
            for i in eachindex(base_chronologies)
                push!(eue_estimator[i], EUECuttingPlaneParams(cem.builds, ram_result, i))
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

            for (i, dispatch) in enumerate(cem.dispatches)
                store(con, n_iters, i, dispatch, sys_built.times)
            end

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
        fullchrono = fullchronologyperiods(sys_built)
        pcm = DispatchProblem(sys_built, 1, fullchrono, optimizer, check_dispatch_voll)
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
    sys::SystemParams, invyear::Int,
    times::DispatchProxyMapping, adequacy::AdequacyResult;
    skip_existing::Bool=false
)

    # TODO: Investigate using adequacy.generation_dEUEs (or both)?
    day_eues = vec(sum(adequacy.eues[:, :, invyear], dims=1))
    og_new_day_idx = argmax(day_eues)

    new_day_idx = og_new_day_idx

    while already_included(new_day_idx, times.days)

        skip_existing && return times

        new_day_idx = new_day_idx > 1 ? new_day_idx - 1 : length(day_eues)

        if new_day_idx == og_new_day_idx
            @warn("No unmodeled stress periods left to add")
            return times
        end

    end

    year, dayofyear = year_dayofyear(new_day_idx, sys.times)
    name = "Y$year D$dayofyear"
    new_day = DispatchDay(name, new_day_idx, times)
    println("Adding period: $name")

    new_days = [times.days; new_day]

    new_mapping = copy(times.mapping)
    new_mapping[new_day_idx] = length(new_days)

    return DispatchProxyMapping(new_days, new_mapping)

end

already_included(day_idx::Int, days::Vector{DispatchDay}) =
    any(d -> d.dispatchday_idx == day_idx, days)

function represented_timeslices(time::DispatchProxyMapping, p::Int)
    T = time.daylength
    return [((d-1)*T+1):(d*T) for d in findall(isequal(p), time.days)]
end

end
