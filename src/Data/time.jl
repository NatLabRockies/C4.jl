const InvestmentYear = Int16

struct TimeIndices
    investment_years::Vector{InvestmentYear}
    dispatch_daycount::Vector{Int} # day count for each dispatch year
    last_operating_year::InvestmentYear
end

n_investment_years(tidxs::TimeIndices) = length(tidxs.investment_years)
n_dispatch_years(tidxs::TimeIndices) = length(tidxs.dispatch_daycount)
n_dispatch_days(tidxs::TimeIndices) = sum(tidxs.dispatch_daycount)
n_dispatch_hours(tidxs::TimeIndices) = n_dispatch_days(tidxs) * N_HOURS_IN_DAY
n_datapoints(tidxs::TimeIndices) = n_investment_years(tidxs) * n_dispatch_hours(tidxs)

dayidx(dispatch_year::Int, dispatch_dayofyear::Int, tidxs::TimeIndices) =
    sum(tidxs.dispatch_daycount[1:(dispatch_year-1)], init=0) + dispatch_dayofyear

annualization_factor(times::TimeIndices) = 8766 / n_dispatch_hours(times)

function year_dayofyear(day_idx::Int, tidxs::TimeIndices)

    y = 0
    year_endday = 0
    year_endday_prev = 0

    while day_idx > year_endday
        y += 1
        year_endday_prev = year_endday
        year_endday += tidxs.dispatch_daycount[y]
    end

    return (y, day_idx - year_endday_prev)

end

function opex_years(times::TimeIndices)

    n_invyears = n_investment_years(times)

    result = Vector{Tuple{Int,Int}}(undef, n_invyears)

    for i in 1:(n_invyears-1)

        result[i] = (
            times.investment_years[i],
            times.investment_years[i+1]-1
        )

    end

    result[end] = (times.investment_years[end], times.last_operating_year)

    return result

end

days(times::TimeIndices) = (
    (year, dayofyear)
        for year in eachindex(times.dispatch_daycount)
        for dayofyear in 1:times.dispatch_daycount[year]
)


function npv_capex(
    f::Function, x::T, times::TimeIndices,
    discount_rate::Float64, npv_year::Int
) where T

    result = 0

    for (i, inv_year) in enumerate(times.investment_years)
        scaling_factor = (1 - discount_rate)^(inv_year - npv_year)
        result += scaling_factor * f(x, i)
    end

    return result

end

function npv_opex(
    f::Function, x::T, times::TimeIndices,
    discount_rate::Float64, npv_year::Int
) where T

    result = 0

    for (i, (y_start, y_end)) in enumerate(opex_years(times))

        scaling_factor = sum((1 - discount_rate)^(y - npv_year)
                             for y in y_start:y_end)

        result += scaling_factor * f(x, i)

    end

    return result

end

function npv_opex(
    f::Function, xs::Vector{T}, times::TimeIndices,
    discount_rate::Float64, npv_year::Int
) where T

    result = 0

    for (i, (y_start, y_end)) in enumerate(opex_years(times))

        scaling_factor = sum((1 - discount_rate)^(y - npv_year)
                             for y in y_start:y_end)

        result += scaling_factor * f(xs[i])

    end

    return result

end

# TODO: Choose more application-agnostic names here?
const InvestmentDataArray{T} = Vector{T} # n_investment_years
const DispatchDataArray{T} = Array{T,3} # N_HOURS_IN_DAY x n_dispatch_days x n_investment_years

function check_dispatchidxs(
    idxs::Vector{NTuple{4,T}}, tidxs::TimeIndices) where T <: Integer

    # Assumed index order: investment_year, dispatch_year, dispatch_dayofyear, dispatch_hour

    issorted(idxs) ||
        error("Data must be provided in chronological order")

    invyears = unique(first.(idxs))
    invyears == tidxs.investment_years ||
        error("Unexpected set of investment years in indices provided: " *
              "expected $(tidxs.investment_years), got $(invyears)")

    n_idxs = length(idxs)
    n_idxs == n_datapoints(tidxs) ||
        error("Unexpected number of indices provided: " *
              "expected $(n_datapoints(tidxs)), got $(n_idxs)")

    idxs_shaped = reshape(idxs, N_HOURS_IN_DAY, n_dispatch_days(tidxs), n_investment_years(tidxs))
    linear_idx = 0

    for invyear in 1:n_investment_years(tidxs)
        for dispyear in 1:n_dispatch_years(tidxs)
            for dayofyear in 1:tidxs.dispatch_daycount[dispyear]
                day = dayidx(dispyear, dayofyear, tidxs)
                for hourofday in 1:N_HOURS_IN_DAY

                    linear_idx += 1
                    idx = idxs_shaped[hourofday, day, invyear]

                    idx[1] == invyears[invyear] ||
                        error("Unexpected investment year at index $(linear_idx): " *
                              "expected $(invyear), got $(idx[1])")

                    idx[2:3] == (dispyear, dayofyear) ||
                        error("Unexpected dispatch year / day-of-year at index $(linear_idx): " *
                              "expected $((dispyear, dayofyear)), got $(idx[2:3])")

                    idx[4] == hourofday ||
                        error("Unexpected dispatch hour of day at index $(linear_idx): " *
                              "expected $(hourofday), got $(idx[4])")

                end
            end
        end
    end

    return

end

shape_dispatchdata(data::AbstractVector, tidxs::TimeIndices) =
    reshape(data, N_HOURS_IN_DAY, n_dispatch_days(tidxs), n_investment_years(tidxs))

function check_investmentidxs(idxs::Vector{<:Integer}, tidxs::TimeIndices)

    issorted(idxs) ||
        error("Data must be provided in chronological order")

    idxs == tidxs.investment_years ||
        error("Unexpected set of investment years in indices provided: " *
              "expected $(tidxs.investment_years), got $(idxs)")

    return

end

shape_investmentdata(data::AbstractVector, tidxs::TimeIndices) = data
