struct AdequacyProblem

    sys::SystemParams
    params::AdequacyParams
    storage_permutation::Vector{Int}
    samples::Int

    function AdequacyProblem(sys::SystemParams; samples::Int)

        demand = sys.demand .* powerunits_MW

        generators_capacity, generators_lambda, generators_mu =
            load_generators(sys)

        storages, storage_perm = load_storages(sys)

        params = AdequacyParams(
            demand,
            generators_capacity, generators_lambda, generators_mu,
            storages)

        return new(sys, params, storage_perm, samples)

    end

end

function load_generators(sys::SystemParams)

    n_timesteps = length(sys.timesteps)
    n_gens, has_variable = count_gens(sys)

    generators_capacity = Matrix{Float64}(undef, n_gens, n_timesteps)
    generators_lambda = Matrix{Float64}(undef, n_timesteps, n_gens)
    generators_mu = Matrix{Float64}(undef, n_timesteps, n_gens)

    g_last = 0

    for tech in sys.thermaltechs_existing
        for site in tech.sites
            for _ in 1:site.units
                g_last += 1
                generators_capacity[g_last, :] .=
                    site.rating .* site.unit_size .* powerunits_MW
                generators_lambda[:, g_last] .= site.λ
                generators_mu[:, g_last] .= site.μ
            end
        end
    end

    if has_variable

        variable_capacity = zeros(n_timesteps)

        for tech in sys.variabletechs_existing
            for site in tech.sites
                variable_capacity .+= site.capacity .* powerunits_MW .* site.availability
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
function count_gens(sys::SystemParams)

    n_gens = 0

    for tech in sys.thermaltechs_existing
        for site in tech.sites
            n_gens += site.units
        end
    end

    has_variable = length(sys.variabletechs_existing) > 0

    n_gens += has_variable

    return n_gens, has_variable

end

function load_storages(sys::SystemParams)

    n_storages = length(sys.storagetechs_existing)

    storages = Vector{StorageParams}(undef, n_storages)
    s_last = 0

    stor_perm = sortperm(
        sys.storagetechs_existing, by=(x -> x.roundtrip_efficiency), rev=true)

    for (s_idx, s) in enumerate(stor_perm)

        stor = sys.storagetechs_existing[s]
        oneway_eff = sqrt(stor.roundtrip_efficiency)

        storages[s_idx] = StorageParams(
            oneway_eff, oneway_eff,
            maxpower(stor) * powerunits_MW, maxenergy(stor) * powerunits_MW)

    end

    return storages, stor_perm

end

struct AdequacyResult

    timestamps::StepRange{DateTime,Hour}

    demand::Vector{Float64}
    lolps::Vector{Float64}
    eues::Vector{Float64}

    generation_dEUEs::Vector{Float64} # n_timesteps
    storage_power_dEUEs::Vector{Float64} # n_storages
    storage_energy_dEUEs::Vector{Float64} # n_storages

end

function solve(prob::AdequacyProblem)

    result = solve(prob.params, samples=prob.samples)

    ip = invperm(prob.storage_permutation)
    stor_power_dEUE = sum(result.storage_power_dEUEs, dims=1)[ip]
    stor_energy_dEUE = sum(result.storage_energy_dEUEs, dims=1)[ip]

    return AdequacyResult(
        prob.sys.timesteps, result.demand, result.lolps, result.eues,
        result.generation_dEUEs, stor_power_dEUE, stor_energy_dEUE)

end

neue(res::AdequacyResult) = sum(res.eues) / sum(res.demand) * 1_000_000
