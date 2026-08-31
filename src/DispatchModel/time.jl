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
    range::UnitRange{Int} # which subset of all days to consider
    mapping::Vector{Int} # mapping from days in range into DispatchDays set

    function DispatchProxyMapping(
        days::Vector{DispatchDay}, mapping::Vector{Int},
        range::UnitRange{Int}=1:length(mapping))

        n_days = length(days)

        length(mapping) == length(range) ||
                error("Mapping length must match provided day range")

        all(d -> 1 <= d <= n_days, mapping) ||
                error("Invalid day index in day mapping")

        all(day -> day.dispatchday_idx in range, days) ||
                error("DispatchDays must be within the provided range")

        new(days, range, mapping)

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
