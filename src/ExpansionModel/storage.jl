struct StorageExpansion <: DispatchableStorageTech

    params::StorageCandidateParams

    power_new::Vector{JuMP.VariableRef}
    energy_new::Vector{JuMP.VariableRef}

    function StorageExpansion(
        m::JuMP.Model, techparams::StorageCandidateParams, times::TimeIndices)

        n_invyears = length(times.investment_years)

        power_new = @variable(m, [1:n_invyears], lower_bound=0)
        set_upper_bound.(power_new, techparams.power_max)
        varnames!(power_new, "storage_new_power[$(techparams.name)]",
                  times.investment_years)

        energy_new = @variable(m, [1:n_invyears], lower_bound=0)
        set_upper_bound.(energy_new, techparams.energy_max)
        varnames!(energy_new, "storage_new_energy[$(techparams.name)]",
                  times.investment_years)

        new(techparams, power_new, energy_new)

    end

end

maxpower(tech::StorageExpansion, i::Int) = sum(tech.power_new[1:i])

maxenergy(tech::StorageExpansion, i::Int) = sum(tech.energy_new[1:i])

cost_capex(tech::StorageExpansion, i::Int) =
    tech.power_new[i] * tech.params.cost_capital_power[i] +
    tech.energy_new[i] * tech.params.cost_capital_energy[i]

cost_fom(tech::StorageExpansion, i::Int) =
    maxpower(tech, i) * tech.params.cost_fom_power[i] +
    maxenergy(tech, i) * tech.params.cost_fom_energy[i]

operating_cost(tech::StorageExpansion, i::Int) =
    tech.params.cost_vom[i]

roundtrip_efficiency(tech::StorageExpansion) =
    tech.params.roundtrip_efficiency

function warmstart_builds!(build::StorageExpansion, prev_build::StorageExpansion)
    JuMP.set_start_value.(build.power_new, value.(prev_build.power_new))
    JuMP.set_start_value.(build.energy_new, value.(prev_build.energy_new))
    return
end

function StorageExistingParams(tech::StorageExpansion)

    new_power = cumsum(value.(tech.power_new))
    new_energy = cumsum(value.(tech.energy_new))
    new_duration = [iszero(new_power[i]) ? 0. : new_energy[i] / new_power[i]
                    for i in eachindex(new_power)]

    params = tech.params

    return StorageExistingParams(
        params.name,
        params.category,
        new_duration,
        params.roundtrip_efficiency,
        params.cost_vom,
        params.cost_fom_power,
        params.cost_fom_energy,
        [StorageExistingSiteParams(tech.params.name * " built", new_power)]
    )

end

function StorageCandidateParams(tech::StorageExpansion)

    params = tech.params

    return StorageCandidateParams(
        params.name,
        params.category,
        params.roundtrip_efficiency,
        params.cost_vom,
        params.cost_fom_power,
        params.cost_fom_energy,
        params.cost_capital_power,
        params.cost_capital_energy,
        params.power_max .- value.(tech.power_new),
        params.energy_max .- value.(tech.energy_new))

end
