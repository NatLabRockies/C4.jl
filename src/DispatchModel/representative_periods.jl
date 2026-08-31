import Statistics: mean, std

# TODO: This is highly simplistic, need to do something more sophisticated
#       eventually - lots of options in the literature
"""
Groups each day in `sys` into a set based on the result of
applying the `grouper` function to the (year, dayofyear) pair. Then chooses
day proxies based on the medoid day in each group, based on average demand
and renewable availability.
"""
function medoid_timegrouping(sys::SystemParams, invyear::Int, grouper::Function)

    day_groups = [grouper(y, d)
        for (y, n_days) in enumerate(sys.times.dispatch_daycount)
        for d in 1:n_days
    ]

    groupnames = unique(day_groups)

    days = Vector{DispatchDay}(undef, length(groupnames))
    mapping = Vector{Int}(undef, length(day_groups))

    n_features = num_features(sys)

    for (group_idx, group_name) in enumerate(groupnames)

        group_days = [d for (d, g) in enumerate(day_groups)
                        if g == group_name]

        group_features = Matrix{Float64}(undef, n_features, length(group_days))

        for (i, day_idx) in enumerate(group_days)
            mapping[day_idx] = group_idx
            labels, features = extract_features(sys, invyear, n_features, day_idx)
            group_features[:, i] = features
        end

        whiten!(group_features)

        day_idx = group_days[find_medoid(group_features)]
        days[group_idx] = DispatchDay(group_name, day_idx, sys.times)

    end

    return DispatchProxyMapping(days, mapping)

end

singleperiod(sys::SystemParams, invyear::Int) =
    medoid_timegrouping(sys, invyear, (y, d) -> "Representative Period")

seasonalperiods(sys::SystemParams, invyear::Int) =
    medoid_timegrouping(sys, invyear, (y, d) -> daytoseason(d))

weeklyperiods(sys::SystemParams, invyear::Int) =
    medoid_timegrouping(sys, invyear, (y, d) -> "W$(daytoweek(d))")

seasonalperiods_byyear(sys::SystemParams, invyear::Int) =
    medoid_timegrouping(sys, invyear, (y, d) -> "Y$y " * daytoseason(d))

weeklyperiods_byyear(sys::SystemParams, invyear::Int) =
    medoid_timegrouping(sys, invyear, (y, d) -> "Y$y W$(daytoweek(d))")

function fullchronologyperiods(sys::SystemParams, dispyear::Int=0)

    d_start, d_end = if dispyear > 0
        n_days = sys.times.dispatch_daycount[dispyear]
        dayidx(dispyear, 1, sys.times), dayidx(dispyear, n_days, sys.times)
    else
        1, n_dispatch_days(sys.times)
    end

    range = d_start:d_end

    days = [
        ((y, doy) = year_dayofyear(d, sys.times);
         DispatchDay("Y$y D$doy", d, sys.times))
     for d in range]

    return DispatchProxyMapping(days, collect(range), range)

end

daytoweek(d::Int) = string(div(d, 7) % 52 + 1)

function daytoseason(d::Int)
    if d <= 60 || d > 335
        "Winter"
    elseif d <= 152
        "Spring"
    elseif d <= 244
        "Summer"
    elseif d <= 335
        "Fall"
    end
end

num_features(sys::SystemParams) =
    length(sys.variabletechs_existing) + length(sys.variabletechs_candidate) + 1

# TODO: Should this also reflect thermal availabilities?
#       Or just wait for a more sophisticated clustering mechanism overall...
"""
Feature vector of average capacity factor for each technology
+ average demand, for the time period corresponding to ts
"""
function extract_features(sys::SystemParams, invyear::Int, n_features::Int, day_idx::Int)

    feature_names = String[]
    feature_levels = Float64[]

    push!(feature_names, "avg_demand")
    push!(feature_levels, mean(sys.demand[:, day_idx, invyear]))

    for tech in sys.variabletechs_existing
        tech_avg_cf =
            mean(mean(site.availability[:, day_idx, invyear]) for site in tech.sites)
        push!(feature_names, tech.name)
        push!(feature_levels, tech_avg_cf)
    end

    for tech in sys.variabletechs_candidate
        tech_avg_cf =
            mean(mean(site.availability[:, day_idx, invyear]) for site in tech.sites)
        push!(feature_names, tech.name)
        push!(feature_levels, tech_avg_cf)
    end

    return feature_names, feature_levels

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
