import Statistics: mean, std
import Dates: Date, DateTime, monthname, month, week

"""
Groups sequential periods in the system timesteps into "days" of length
`daylength`. Each `day` is then grouped into a set based on the result of
applying the `grouper` function to one of the periods in each "day".

Note that while `daylength` defaults to 24-hour periods, "days" could in theory
be longer or shorter as well (e.g. 12 hours, 48 hours, etc).
"""
function medoid_timegrouping(
    sys::SystemParams, grouper::Function, daylength::Int=24)

    days = reshape(sys.timesteps, daylength, :)
    firstperiods = vec(days[1,:])

    day_groups = grouper.(firstperiods)
    groups = unique(day_groups)

    periods = Vector{TimePeriod}(undef, length(groups))
    days = Vector{Int}(undef, length(day_groups))

    n_features = num_features(sys)

    for (group_idx, group) in enumerate(groups)

        group_days = [d for (d, daygroup) in enumerate(day_groups) if daygroup == group]
        group_features = Matrix{Float64}(undef, n_features, length(group_days))

        for (i, day_idx) in enumerate(group_days)
            days[day_idx] = group_idx
            timerange = hours_from_day(day_idx, daylength)
            labels, features = extract_features(sys, n_features, timerange)
            group_features[:, i] = features
        end

        whiten!(group_features)

        medoid_day_idx = group_days[find_medoid(group_features)]
        medoid_timesteps = hours_from_day(medoid_day_idx, daylength)
        periods[group_idx] = TimePeriod(medoid_timesteps, group)

    end

    return TimeProxyAssignment(periods, days)

end

singleperiod(sys::SystemParams; daylength::Int=24) =
    medoid_timegrouping(sys, x -> "Representative Period", daylength)

seasonalperiods(sys::SystemParams; daylength::Int=24) =
    medoid_timegrouping(sys, seasonname, daylength)

monthlyperiods(sys::SystemParams; daylength::Int=24) =
    medoid_timegrouping(sys, monthname, daylength)

weeklyperiods(sys::SystemParams; daylength::Int=24) =
    medoid_timegrouping(sys, weekname, daylength)

seasonalperiods_byyear(sys::SystemParams; daylength::Int=24) =
    medoid_timegrouping(sys, byyear(seasonname), daylength)

monthlyperiods_byyear(sys::SystemParams; daylength::Int=24) =
    medoid_timegrouping(sys, byyear(monthname), daylength)

weeklyperiods_byyear(sys::SystemParams; daylength::Int=24) =
    medoid_timegrouping(sys, byyear(weekname), daylength)

# Redundant with full chronology periods when using 24-hour days
dailyperiods(sys::SystemParams; daylength::Int=24) =
    medoid_timegrouping(sys, string ∘ Date, daylength)

fullchronologyperiods(sys::SystemParams; daylength::Int=24) =
    medoid_timegrouping(sys, string, daylength)

weekname(dt::DateTime) = "Week " * string(week(dt))

function seasonname(dt::DateTime)
    m = month(dt)
    if m <=2 || m == 12
        "Winter"
    elseif m <= 5
        "Spring"
    elseif m <= 8
        "Summer"
    elseif m <= 11
        "Fall"
    end
end

byyear(f::Function) = (dt -> f(dt) * " " * string(year(dt)))

num_features(sys::SystemParams) =
    length(sys.variabletechs_existing) + length(sys.variabletechs_candidate) + 1

"""
Feature vector of average capacity factor for each technology
+ average demand, for the time period corresponding to ts
"""
function extract_features(sys::SystemParams, n_features::Int, ts::UnitRange{Int})

    demand = 0.
    tech_cfs = Dict{String,Vector{Float64}}()

    demand += mean(sys.demand[ts])

    for tech in sys.variabletechs_existing

        haskey(tech_cfs, tech.name) ||
            (tech_cfs[tech.name] = Float64[])

        for site in tech.sites
            site_cf = mean(site.availability[ts])
            push!(tech_cfs[tech.name], site_cf)
        end

    end

    for tech in sys.variabletechs_candidate

        haskey(tech_cfs, tech.name) ||
            (tech_cfs[tech.name] = Float64[])

        for site in tech.sites
            site_cf = mean(site.availability[ts])
            push!(tech_cfs[tech.name], site_cf)
        end

    end


    features = [tech => mean(site_cfs) for (tech, site_cfs) in tech_cfs]
    push!(features, "avg_demand" => demand)
    sort!(features)

    return first.(features), last.(features)

end

"""
Normalize a feature matrix of n_features x n_samples to zero mean, unity std
"""
function whiten!(features::Matrix{Float64})
    features .-= mean(features, dims=2)
    features ./= std(features, dims=2)
    return
end

"""
Extract the medoid sample from a matrix of n_features x n_samples
"""
function find_medoid(features::Matrix{Float64})

    n_features, n_samples = size(features)
    tot_dists = zeros(n_samples)

    for i in 1:n_samples
        for j in 1:(i-1)
            d_ij = sqrt(sum(abs2.(features[:,i] .- features[:,j])))
            tot_dists[i] += d_ij
            tot_dists[j] += d_ij
        end
    end

    return argmin(tot_dists)

end
