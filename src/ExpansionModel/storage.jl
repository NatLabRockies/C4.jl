struct StorageExpansion <: DispatchableStorageTech

    params::StorageCandidateParams

    power_new::Vector{JuMP.VariableRef}

    function StorageExpansion(
        m::JuMP.Model, techparams::StorageCandidateParams, times::TimeIndices)

        n_invyears = length(times.investment_years)

        power_new = @variable(m, [1:n_invyears], lower_bound=0)
        set_upper_bound.(power_new, techparams.power_max)
        varnames!(power_new, "storage_new_power[$(techparams.name)]",
                  times.investment_years)

        new(techparams, power_new)

    end

end

duration(tech::StorageExpansion) = tech.params.duration

maxpower(tech::StorageExpansion, i::Int) = sum(tech.power_new[1:i])

maxenergy(tech::StorageExpansion, i::Int) = maxpower(tech, i) * duration(tech)

cost_capex(tech::StorageExpansion, i::Int, wacc::Float64) =
    tech.power_new[i] * (
        cost_capex_power(tech.params, i, wacc) +
        duration(tech) * cost_capex_energy(tech.params, i, wacc))

cost_fom(tech::StorageExpansion, i::Int) =
    maxpower(tech, i) * tech.params.cost_fom_power[i] +
    maxenergy(tech, i) * tech.params.cost_fom_energy[i]

operating_cost(tech::StorageExpansion, i::Int) =
    tech.params.cost_vom[i]

roundtrip_efficiency(tech::StorageExpansion) =
    tech.params.roundtrip_efficiency

function warmstart_builds!(build::StorageExpansion, prev_build::StorageExpansion)
    JuMP.set_start_value.(build.power_new, value.(prev_build.power_new))
    return
end

function StorageExistingParams(tech::StorageExpansion)

    n_invyears = length(tech.power_new)

    new_power = cumsum(value.(tech.power_new))

    params = tech.params

    return StorageExistingParams(
        params.name,
        params.category,
        fill(params.duration, n_invyears),
        params.roundtrip_efficiency,
        params.cost_vom,
        params.cost_fom_power,
        params.cost_fom_energy,
        [StorageExistingSiteParams(tech.params.name * " built", new_power)]
    )

end

function StorageCandidateParams(tech::StorageExpansion)

    params = tech.params

    new_powers = value.(tech.power_new)

    return StorageCandidateParams(
        params.name,
        params.category,
        params.roundtrip_efficiency,
        params.duration,
        params.cost_vom,
        params.cost_fom_power,
        params.cost_fom_energy,
        params.cost_overnightcapital_power,
        params.cost_overnightcapital_energy,
        params.capital_recovery_period,
        params.power_max .- new_powers)

end
