struct AdequacyProblem

    sys::SystemParams
    params::Vector{AdequacyParams} # n_investment_years
    storage_permutation::Vector{Int}
    samples::Int

    function AdequacyProblem(sys::SystemParams; samples::Int)

        stor_perm = sortperm(
            sys.storagetechs_existing, by=(x -> x.roundtrip_efficiency), rev=true)

        params = Vector{AdequacyParams}(undef, n_investment_years(sys.times))

        for i in eachindex(sys.times.investment_years)

            demand = vec(sys.demand[:, :, i]) .* powerunits_MW

            generators_capacity, generators_lambda, generators_mu =
                load_generators(sys, i)

            storages = load_storages(sys, i, stor_perm)

            params[i] = AdequacyParams(
                demand,
                generators_capacity, generators_lambda, generators_mu,
                storages)

        end

        return new(sys, params, stor_perm, samples)

    end

end

# TODO: Convert to generating AdequacyProblem from a generic DispatchableSystem
#       (not just SystemParams - allows direct SystemExpansion conversion as well)
function load_generators(sys::SystemParams, i::Int)

    n_timesteps = n_dispatch_hours(sys.times)
    n_gens, has_variable = count_gens(sys, i)

    generators_capacity = Matrix{Float64}(undef, n_gens, n_timesteps)
    generators_lambda = Matrix{Float64}(undef, n_timesteps, n_gens)
    generators_mu = Matrix{Float64}(undef, n_timesteps, n_gens)

    g_last = 0

    for tech in sys.thermaltechs_existing
        tech_ratedcap = vec(tech.rating[:, :, i]) .* tech.unit_size .* powerunits_MW
        for site in tech.sites
            for _ in 1:site.units[i]
                g_last += 1
                generators_capacity[g_last, :] .= tech_ratedcap
                generators_lambda[:, g_last] .= vec(site.λ[:, :, i])
                generators_mu[:, g_last] .= vec(site.μ[:, :, i])
            end
        end
    end

    if has_variable

        variable_capacity = zeros(n_timesteps)

        for tech in sys.variabletechs_existing
            for site in tech.sites
                variable_capacity .+= site.capacity[i] .* powerunits_MW .*
                        vec(site.availability[:, :, i])
            end
        end

        g_last += 1
        generators_capacity[g_last, :] .= variable_capacity
        generators_lambda[:, g_last] .= 0.
        generators_mu[:, g_last] .= 1.

    end

    return generators_capacity, generators_lambda, generators_mu

end

"""
Counts the number of statistically-independent generators in the system.
Each unit of a thermal tech counts as a new generator, while
VRE across all techs and sites within a region is pooled.
"""
function count_gens(sys::SystemParams, i::Int)

    n_gens = 0

    for tech in sys.thermaltechs_existing
        for site in tech.sites
            n_gens += site.units[i]
        end
    end

    has_variable = length(sys.variabletechs_existing) > 0

    n_gens += has_variable

    return n_gens, has_variable

end

function load_storages(sys::SystemParams, i::Int, stor_perm::Vector{Int})

    n_storages = length(sys.storagetechs_existing)

    storages = Vector{StorageParams}(undef, n_storages)
    s_last = 0

    for (s_idx, s) in enumerate(stor_perm)

        stor = sys.storagetechs_existing[s]
        oneway_eff = sqrt(stor.roundtrip_efficiency)

        storages[s_idx] = StorageParams(
            oneway_eff, oneway_eff,
            maxpower(stor, i) * powerunits_MW, maxenergy(stor, i) * powerunits_MW)

    end

    return storages

end

struct AdequacyResult

    times::TimeIndices

    demand::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years
    lolps::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years
    eues::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years

    generation_dEUEs::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years

    storage_power_dEUEs::Matrix{Float64} # n_storages x n_investment_years
    storage_energy_dEUEs::Matrix{Float64} # n_storages x n_investment_years

end

function solve(prob::AdequacyProblem)

    n_days = n_dispatch_days(prob.sys.times)
    n_invyears = n_investment_years(prob.sys.times)
    n_storages = length(prob.storage_permutation)

    ip = invperm(prob.storage_permutation)

    demand = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)
    lolps = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)
    eues = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)
    generation_dEUEs = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)

    stor_power_dEUE = Matrix{Float64}(undef, n_storages, n_invyears)
    stor_energy_dEUE = Matrix{Float64}(undef, n_storages, n_invyears)

    for (i, params) in enumerate(prob.params)

        result = solve(params, samples=prob.samples)

        demand[:, :, i] = reshape(result.demand, N_HOURS_IN_DAY, n_days)
        lolps[:, :, i] = reshape(result.lolps, N_HOURS_IN_DAY, n_days)
        eues[:, :, i] = reshape(result.eues, N_HOURS_IN_DAY, n_days)
        generation_dEUEs[:, :, i] = reshape(result.generation_dEUEs,
                                            N_HOURS_IN_DAY, n_days)

        stor_power_dEUE[:, i] = sum(result.storage_power_dEUEs, dims=1)[ip]
        stor_energy_dEUE[:, i] = sum(result.storage_energy_dEUEs, dims=1)[ip]

    end

    return AdequacyResult(
        prob.sys.times, demand, lolps, eues, generation_dEUEs,
        stor_power_dEUE, stor_energy_dEUE)

end

neues(res::AdequacyResult) =
    [neue(res, i) for i in 1:n_investment_years(res.times)]

neue(res::AdequacyResult, i::Int) =
    sum(res.eues[:, :, i]) / sum(res.demand[:, :, i]) * 1_000_000
