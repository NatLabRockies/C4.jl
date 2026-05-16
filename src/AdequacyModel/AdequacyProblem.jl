struct AdequacyProblem

    sys::SystemParams
    params::AdequacyParams
    storage_permutation::Vector{Int}
    samples::Int

    function AdequacyProblem(sys::SystemParams; samples::Int)

        demand = sys.regions[1].demand .* powerunits_MW
        generators = load_generators(sys)
        storages, storage_perm = load_storages(sys)

        params = AdequacyParams(demand, generators, storages)

        return new(sys, params, storage_perm, samples)

    end

end

function load_generators(sys::SystemParams)

    n_timesteps = length(sys.timesteps)
    n_gens, has_variable = count_gens(sys)
    region = first(sys.regions)

    gens = Matrix{GeneratorParams}(undef, n_gens, n_timesteps)
    g_last = 0

    for tech in region.thermaltechs_existing
        for site in tech.sites
            for _ in 1:site.units
                g_last += 1
                gens[g_last, :] .= GeneratorParams.(
                    site.rating .* site.unit_size .* powerunits_MW,
                    site.λ,  site.μ)
            end
        end
    end

    if has_variable

        variable_capacity = zeros(n_timesteps)

        for tech in region.variabletechs_existing
            for site in tech.sites
                variable_capacity .+= site.capacity .* powerunits_MW .* site.availability
            end
        end

        g_last += 1
        gens[g_last, :] .= GeneratorParams.(variable_capacity, 0.,  1.)

    end

    return gens

end

"""
Counts the number of statistically-independent generators in the system.
Each unit of a thermal tech counts as a new generator, while
VRE across all techs and sites within a region is pooled.
"""
function count_gens(sys::SystemParams)

    region = first(sys.regions)
    n_gens = 0

    for tech in region.thermaltechs_existing
        for site in tech.sites
            n_gens += site.units
        end
    end

    has_variable = length(region.variabletechs_existing) > 0

    n_gens += has_variable

    return n_gens, has_variable

end

function load_storages(sys::SystemParams)

    region = first(sys.regions)
    n_storages = length(region.storagetechs_existing)

    storages = Vector{StorageParams}(undef, n_storages)
    s_last = 0

    stor_perm = sortperm(
        region.storagetechs_existing, by=(x -> x.roundtrip_efficiency), rev=true)

    for (s_idx, s) in enumerate(stor_perm)

        stor = region.storagetechs_existing[s]
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
