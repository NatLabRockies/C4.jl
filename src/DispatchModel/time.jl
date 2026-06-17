struct DispatchDay

    name::String

    dispatchday_idx::Int

    dispatchyear_idx::Int
    dispatchdayofyear_idx::Int

    DispatchDay(name::String, d::Int, times::TimeIndices) =
        new(name, d, year_dayofyear(d, times)...)

end

struct DispatchProxyMapping

    days::Vector{DispatchDay} # set of DispatchDays to be included in optimization
    mapping::Vector{Int} # mapping from all days into DispatchDays set

    function DispatchProxyMapping(days::Vector{DispatchDay}, mapping::Vector{Int})

        n_days = length(days)

        all(d -> 1 <= d <= n_days, mapping) ||
                error("Invalid day index in day mapping")

        new(days, mapping)

    end

end

n_decision_days(dpm::DispatchProxyMapping) =
    length(dpm.days)

n_represented_days(dpm::DispatchProxyMapping) =
    length(dpm.mapping)

n_decision_hours(dpm::DispatchProxyMapping) =
    n_decision_days(dpm) * N_HOURS_IN_DAY

n_represented_hours(dpm::DispatchProxyMapping) =
    n_represented_days(dpm) * N_HOURS_IN_DAY

annualization_factor(dpm::DispatchProxyMapping) = 8766 / n_represented_hours(dpm)
