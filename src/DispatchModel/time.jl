# The index of the day (2nd dimension) in a DispatchDataArray
const DispatchDataDayIdx = Int

# The index of a DispatchDay in DispatchProxyMappings.days
const DispatchDayIdx = Int

struct DispatchDay

    name::String

    dispatchday_idx::DispatchDataDayIdx

    dispatchyear_idx::Int
    dispatchdayofyear_idx::Int

    DispatchDay(name::String, d::DispatchDataDayIdx, times::TimeIndices) =
        new(name, d, year_dayofyear(d, times)...)

end

"""
Mapping defining relationship from represented days (`range`) into
representative days (`mapping`). The latter is indexed relative to the parent
`DispatchProxyMappings` days property. Used to define the recurrences in a
DispatchSequence.
"""
struct DispatchProxyMapping

    range::UnitRange{DispatchDataDayIdx} # which contiguous subset of all days to consider
    mapping::Vector{DispatchDayIdx} # mapping from days in range into DispatchDay set

    function DispatchProxyMapping(
        range::UnitRange{DispatchDataDayIdx}, mapping::Vector{DispatchDayIdx})

        length(mapping) == length(range) ||
                error("Mapping length must match provided day range")

        return new(range, mapping)

    end

end

struct DispatchProxyMappings

    days::Vector{DispatchDay} # set of DispatchDays to be included in optimization

    mappings::Vector{DispatchProxyMapping} # set of independent sequences referencing days

    function DispatchProxyMappings(
        days::Vector{DispatchDay},
        mappings::Vector{DispatchProxyMapping})

        n_days = length(days)

        for mapping in mappings
            all(d -> 1 <= d <= n_days, mapping.mapping) ||
                    error("Invalid day index in day mapping")
        end

        new(days, mappings)

    end

end

n_decision_days(dpms::DispatchProxyMappings) =
    length(dpms.days)

n_represented_days(dpms::DispatchProxyMappings) =
    [length(dpm.mapping) for dpm in dpms.mappings]

n_decision_hours(dpm::DispatchProxyMappings) =
    n_decision_days(dpm) * N_HOURS_IN_DAY

n_represented_hours(dpm::DispatchProxyMappings) =
    n_represented_days(dpm) .* N_HOURS_IN_DAY

annualization_factor(dpm::DispatchProxyMappings) = 8766 / sum(n_represented_hours(dpm))
