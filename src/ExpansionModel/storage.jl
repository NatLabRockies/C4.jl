struct StorageExpansion <: DispatchableStorageTech

    params::StorageCandidateParams

    power_new::JuMP.VariableRef
    energy_new::JuMP.VariableRef

    function StorageExpansion(
        m::JuMP.Model, techparams::StorageCandidateParams)

        power_new = @variable(m, lower_bound=0, upper_bound=techparams.power_max[1])
        JuMP.set_name(power_new, "storage_new_power[$(techparams.name)]")

        energy_new = @variable(m, lower_bound=0, upper_bound=techparams.energy_max[1])
        JuMP.set_name(energy_new, "storage_new_energy[$(techparams.name)]")

        new(techparams, power_new, energy_new)

    end

end

maxpower(tech::StorageExpansion) = tech.power_new

maxenergy(tech::StorageExpansion) = tech.energy_new

cost(tech::StorageExpansion) =
    tech.power_new * tech.params.cost_capital_power[1] +
    tech.energy_new * tech.params.cost_capital_energy[1]

operating_cost(tech::StorageExpansion) =
    tech.params.cost_vom[1]

roundtrip_efficiency(tech::StorageExpansion) =
    tech.params.roundtrip_efficiency

function warmstart_builds!(build::StorageExpansion, prev_build::StorageExpansion)
    JuMP.set_start_value(build.power_new, value(prev_build.power_new))
    JuMP.set_start_value(build.energy_new, value(prev_build.energy_new))
    return
end

function StorageExistingParams(tech::StorageExpansion)

    new_power = value(tech.power_new)
    new_energy = value(tech.energy_new)
    new_duration = iszero(new_power) ? 0. : new_energy / new_power

    params = tech.params

    return StorageExistingParams(
        params.name,
        params.category,
        new_duration,
        params.roundtrip_efficiency,
        params.cost_vom,
        [StorageExistingSiteParams(tech.params.name * " built", [new_power])]
    )

end

function StorageCandidateParams(tech::StorageExpansion)

    params = tech.params

    return StorageCandidateParams(
        params.name,
        params.category,
        params.roundtrip_efficiency,
        params.cost_vom,
        params.cost_capital_power,
        params.cost_capital_energy,
        [params.power_max[1] .- value(tech.power_new)],
        [params.energy_max[1] .- value(tech.energy_new)])

end
