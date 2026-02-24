struct StorageExpansion <: StorageTechnology

    params::StorageCandidateParams

    power_new::JuMP.VariableRef

    function StorageExpansion(
        m::JuMP.Model, techparams::StorageCandidateParams, regionparams::RegionParams
    )

        fullname = join([regionparams.name, techparams.name], ",")

        power_new = @variable(m, lower_bound=0, upper_bound=techparams.power_max)
        JuMP.set_name(power_new, "storage_new_power[$fullname]")

        new(techparams, power_new)

    end

end

maxpower(tech::StorageExpansion) = tech.power_new

maxenergy(tech::StorageExpansion) = tech.power_new * tech.params.duration

cost(tech::StorageExpansion) =
    tech.power_new * tech.params.cost_capital_power

operating_cost(tech::StorageExpansion) =
    tech.params.cost_operation

roundtrip_efficiency(tech::StorageExpansion) =
    tech.params.roundtrip_efficiency

function warmstart_builds!(build::StorageExpansion, prev_build::StorageExpansion)
    JuMP.set_start_value(build.power_new, value(prev_build.power_new))
    return
end

function StorageExistingParams(tech::StorageExpansion)

    new_power = value(tech.power_new)

    params = tech.params

    return StorageExistingParams(
        params.name,
        params.category,
        params.cost_operation,
        params.roundtrip_efficiency,
        params.duration,
        [StorageExistingSiteParams("", new_power)]
    )

end

function StorageCandidateParams(tech::StorageExpansion)

    params = tech.params

    return StorageCandidateParams(
        params.name,
        params.category,
        params.cost_operation,
        params.roundtrip_efficiency,
        params.cost_capital_power,
        params.power_max - value(tech.power_new),
        params.duration)

end
