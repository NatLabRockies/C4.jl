module IterationModel

using C4.Data
using C4.AdequacyModel
using C4.DispatchModel
using C4.ExpansionModel

import ..store, ..powerunits_MW
import C4.ExpansionModel: RiskEstimateParams, RiskEstimatePeriodParams,
                          RiskEstimatePlaneParams

import Dates: Date, now
import DBInterface
import DelimitedFiles: writedlm
import DuckDB
import JuMP: value
import PRAS: EUE, NEUE, val

export iterate_ra_cem

function iterate_ra_cem(
    sys::SystemParams, base_chronology::TimeProxyAssignment,
    max_neues::Union{Vector{Float64},Matrix{Float64},Dict{String,Vector{Float64}}}, optimizer;
    nsamples::Int=1000, skip_existing_stress_periods::Bool=false,
    timeout::Float64=Inf, first_feasible::Bool=true,
    aspp::Bool=true, endog_risk::Bool=true, outfile::String="",
    check_dispatch::Bool=false, check_dispatch_voll::Float64=NaN,
    seasonal_constraints::Bool=false)

    _chronology = deepcopy(base_chronology)
    persist = length(outfile) > 0
    timeout += time()
    n_regions = length(sys.regions)

    if seasonal_constraints && max_neues isa Matrix{Float64}
        throw(ArgumentError(
            "Seasonal constraints with matrix max_neues are order-ambiguous. " *
            "Pass max_neues as Dict{String,Vector{Float64}} keyed by base_chronology period names."
        ))
    end

    max_eues, max_eues_by_period, adequacy_limits = eue_limits_from_max_neues(
        sys,
        base_chronology,
        max_neues,
    )

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

    eue_estimator = nullestimator(chronology, n_regions)

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
    adequacy_results = ExpansionAdequacyContext[]
    n_iters = 0

    while (time() < timeout)

        n_iters += 1
        cem_start = now()
        
        eue_limits = seasonal_constraints ? max_eues_by_period : max_eues
        cem = ExpansionProblem(sys, eue_estimator, eue_limits, optimizer, seasonal_constraints, _chronology)
        isnothing(prev_cem) || warmstart_builds!(cem, prev_cem)

        println("Recurrences:")
        for recc in cem.reliabilitydispatch.recurrences
            println(recc.repetitions, " x ", recc.dispatch.period.name)
        end

        solve!(cem)
        cem_end = now()

        ram_start = now()
        sys_built = SystemParams(cem)
        ram = AdequacyProblem(sys_built, samples=nsamples)
        ram_result = solve(ram)
        push!(adequacy_results, ExpansionAdequacyContext(cem, ram_result))
        ram_end = now()

        show_neues(ram_result)

        is_adequate = all(region_neues(ram_result) .<= adequacy_limits)

        aug_start = now()

        aspp && (chronology = add_stressperiod(sys, chronology, ram_result,
                                               skip_existing=skip_existing_stress_periods))

        eue_estimator = if endog_risk
            RiskEstimateParams(chronology, adequacy_results)
        else
            nullestimator(chronology, n_regions)
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

function eue_limits_from_max_neues(
    sys::SystemParams,
    base_chronology::TimeProxyAssignment,
    max_neues::Union{Vector{Float64},Matrix{Float64},Dict{String,Vector{Float64}}},
)

    annual_demands = [sum(region.demand) for region in sys.regions]
    annual_eue_factors = annual_demands .* 1e-6

    n_regions = length(sys.regions)
    n_periods = length(base_chronology.periods)

    if max_neues isa Vector{Float64}
        length(max_neues) == n_regions || throw(DimensionMismatch(
            "max_neues vector length $(length(max_neues)) does not match number of regions $n_regions."
        ))

        max_eues = max_neues .* annual_eue_factors
        max_eues_by_period = zeros(n_regions, n_periods)

        for p in 1:n_periods
            represented_ts = represented_timeslices(base_chronology, p)

            for r in 1:n_regions
                period_demand = sum(sum(sys.regions[r].demand[ts]) for ts in represented_ts)
                demand_share = annual_demands[r] > 0 ? period_demand / annual_demands[r] : 0.0
                max_eues_by_period[r, p] = max_eues[r] * demand_share
            end
        end

        adequacy_limits = max_neues
        return max_eues, max_eues_by_period, adequacy_limits
    end

    ordered_max_neues = if max_neues isa Matrix{Float64}
        size(max_neues, 1) == n_regions || throw(DimensionMismatch(
            "max_neues matrix row count $(size(max_neues, 1)) does not match number of regions $n_regions."
        ))
        size(max_neues, 2) == n_periods || throw(DimensionMismatch(
            "max_neues matrix column count $(size(max_neues, 2)) does not match number of base chronology periods $n_periods."
        ))
        max_neues
    else
        max_neues_matrix_from_period_dict(max_neues, base_chronology, n_regions)
    end

    max_eues_by_period = ordered_max_neues .* annual_eue_factors
    max_eues = vec(sum(max_eues_by_period, dims=2))
    adequacy_limits = vec(sum(ordered_max_neues, dims=2))

    return max_eues, max_eues_by_period, adequacy_limits

end

function max_neues_matrix_from_period_dict(
    max_neues::Dict{String,Vector{Float64}},
    base_chronology::TimeProxyAssignment,
    n_regions::Int,
)

    normalized = Dict{String,Vector{Float64}}()

    for (name, values) in max_neues
        normalized_name = lowercase(strip(name))
        haskey(normalized, normalized_name) && throw(ArgumentError(
            "Duplicate period name '$name' after normalization."
        ))
        length(values) == n_regions || throw(DimensionMismatch(
            "max_neues[$name] length $(length(values)) does not match number of regions $n_regions."
        ))
        normalized[normalized_name] = values
    end

    chronology_period_names = lowercase.(strip.([string(period.name) for period in base_chronology.periods]))
    ordered_max_neues = Matrix{Float64}(undef, n_regions, length(chronology_period_names))

    for (p, name) in enumerate(chronology_period_names)
        haskey(normalized, name) || throw(ArgumentError(
            "Period name '$name' from base_chronology.periods is missing from max_neues keys."
        ))
        ordered_max_neues[:, p] = normalized[name]
    end

    extra_names = setdiff(Set(keys(normalized)), Set(chronology_period_names))
    isempty(extra_names) || throw(ArgumentError(
        "max_neues contains extra period names not in base_chronology.periods: $(join(sort!(collect(extra_names)), ", "))."
    ))

    return ordered_max_neues

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

function RiskEstimateParams(
    time::TimeProxyAssignment, results::Vector{ExpansionAdequacyContext})

    period_params = [
        RiskEstimatePeriodParams(results, time, p)
        for p in eachindex(time.periods)
    ]

    return RiskEstimateParams(time, period_params)

end

function RiskEstimatePeriodParams(
    adequacycontexts::Vector{ExpansionAdequacyContext},
    time::TimeProxyAssignment,
    p::Int
)

    R = size(first(adequacycontexts).available_capacity, 1)
    T = time.daylength
    J = length(adequacycontexts)

    representative_ts = time.periods[p].timesteps
    represented_ts = represented_timeslices(time, p)

    planes = Array{RiskEstimatePlaneParams,3}(undef, R, T, J)

    for (j, adequacycontext) in enumerate(adequacycontexts)

        shortfalls = adequacycontext.adequacy.shortfalls

        availablecapacity =
            adequacycontext.available_capacity[:, representative_ts]

        base_eue = zeros(R,T)
        dEUE = zeros(R,T)

        for ts in represented_ts
            base_eue .+= shortfalls.shortfall_mean[:, ts] ./ powerunits_MW
            dEUE .+= shortfalls.eventperiod_regionperiod_mean[:, ts]
        end

        planes[:,:,j] .= RiskEstimatePlaneParams.(
            base_eue, availablecapacity, dEUE)

    end

    return planes

end

function represented_timeslices(time::TimeProxyAssignment, p::Int)
    T = time.daylength
    return [((d-1)*T+1):(d*T) for d in findall(isequal(p), time.days)]
end

end
