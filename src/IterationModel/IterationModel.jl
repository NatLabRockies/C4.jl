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
    sys::SystemParams, base_chronology::TimeProxyAssignment,
    max_neue::Float64, optimizer; neue_tol::Float64=.01,
    nsamples::Int=1000, skip_existing_stress_periods::Bool=false,
    max_co2_intensity::Float64=NaN, # kg/MWh
    co2_offset_price::Float64=9999., # $/tonne CO2
    timeout::Float64=Inf, first_feasible::Bool=true,
    aspp::Bool=true, endog_risk::Bool=true, outfile::String="",
    check_dispatch::Bool=false, check_dispatch_voll::Real=NaN,
    unit_commitment::Bool=true)

    persist = length(outfile) > 0
    timeout += time()

    demand = total_demand(sys)

    max_eue = max_neue * demand * 1e-6
    max_co2 = max_co2_intensity * (demand * powerunits_MW) * 1e-9 # in Megatonnes

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
    n_iters = 0

    while (time() < timeout)

        n_iters += 1
        cem_start = now()

        cem = ExpansionProblem(sys, chronology, eue_estimator, max_eue,
                               max_co2, co2_offset_price, optimizer,
                               unit_commitment=unit_commitment)

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
            push!(eue_estimator, EUECuttingPlaneParams(cem.builds, ram_result))
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

end
