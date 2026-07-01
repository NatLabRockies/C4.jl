struct StorageParams
    charge_eff::Float64
    discharge_eff::Float64
    power_capacity::Float64
    energy_capacity::Float64
end

struct AdequacyParams

    n_timesteps::Int
    n_generators::Int
    n_storages::Int

    demand::Vector{Float64} # n_timesteps

    # Note this index ordering is deliberately inconsistent,
    # for better contiguous memory access
    generators_capacity::Matrix{Float64} # n_generators x n_timesteps
    generators_lambda::Matrix{Float64} # n_timesteps x n_generators
    generators_mu::Matrix{Float64} # n_timesteps x n_generators

    # Note: Provided storages MUST be pre-sorted by round-trip efficiency
    storages::Vector{StorageParams} # n_storages

    function AdequacyParams(
        demand::Vector{Float64},
        generators_capacity::Matrix{Float64},
        generators_lambda::Matrix{Float64},
        generators_mu::Matrix{Float64},
        storages::Vector{StorageParams})

        n_timesteps = length(demand)
        n_generators = size(generators_capacity, 1)
        n_storages = length(storages)

        size(generators_capacity, 2) == n_timesteps || error("Inconsistent number of timesteps")

        size(generators_lambda, 1) == n_timesteps || error("Inconsistent number of timesteps")
        size(generators_lambda, 2) == n_generators || error("Inconsistent number of generators")

        size(generators_mu, 1) == n_timesteps || error("Inconsistent number of timesteps")
        size(generators_mu, 2) == n_generators || error("Inconsistent number of generators")

        new(n_timesteps, n_generators, n_storages, demand,
            generators_capacity, generators_lambda, generators_mu, storages)

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

    for s in 1:n_storages

        stor = sys.storagetechs_existing[s]
        oneway_eff = sqrt(stor.roundtrip_efficiency)

        storages[s] = StorageParams(
            oneway_eff, oneway_eff,
            maxpower(stor) * powerunits_MW, maxenergy(stor) * powerunits_MW)

    end

    return storages

end
