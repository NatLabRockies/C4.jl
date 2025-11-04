struct ThermalExpansion <: ThermalTechnology

    params::ThermalCandidateParams
    units_new::JuMP.VariableRef

    function ThermalExpansion(
        m::JuMP.Model, techparams::ThermalCandidateParams)

        units_new = @variable(m, integer=true, lower_bound=0, upper_bound=techparams.max_units)
        JuMP.set_name(units_new, "thermal_new_units[$(techparams.name)]")

        new(techparams, units_new)

    end

end

nameplatecapacity(tech::ThermalExpansion) =
        tech.units_new * tech.params.unit_size

availablecapacity(tech::ThermalExpansion, t::Int) =
        tech.units_new * tech.params.unit_size * availability(tech.params, t)

cost(build::ThermalExpansion) =
    build.units_new * build.params.unit_size * build.params.cost_capital

cost_startup(build::ThermalExpansion) =
    build.params.startup_heat * build.params.fuel.cost

cost_generation(tech::ThermalExpansion) = cost_generation(tech.params)

max_unit_ramp(tech::ThermalExpansion) = tech.params.max_ramp

num_units(tech::ThermalExpansion) = tech.units_new

unit_size(tech::ThermalExpansion) = tech.params.unit_size

min_gen(tech::ThermalExpansion) = tech.params.min_gen

min_uptime(tech::ThermalExpansion) = tech.params.min_uptime

min_downtime(tech::ThermalExpansion) = tech.params.min_downtime

function ThermalExistingParams(tech::ThermalExpansion)

    new_units = round(Int, value(tech.units_new))
    params = tech.params

    new_site = ThermalExistingSiteParams(
        "",
        new_units,
        params.rating,
        params.λ,
        params.μ)

    return ThermalExistingParams(
        params.name,
        params.category,
        params.fuel,
        params.heat_rate,
        params.startup_heat,
        params.cost_vom,
        params.unit_size,
        params.min_gen,
        params.max_ramp,
        params.min_uptime,
        params.min_downtime,
        [new_site])

end

function ThermalCandidateParams(tech::ThermalExpansion)

    new_units = round(Int, value(tech.units_new))
    params = tech.params

    return ThermalCandidateParams(
        params.name,
        params.category,
        params.fuel,
        params.heat_rate,
        params.startup_heat,
        params.cost_vom,
        params.cost_capital,
        params.max_units - new_units,
        params.unit_size,
        params.min_gen,
        params.max_ramp,
        params.min_uptime,
        params.min_downtime,
        params.rating,
        params.λ,
        params.μ)

end

function warmstart_builds!(build::ThermalExpansion, prev_build::ThermalExpansion)
    JuMP.set_start_value(build.units_new, value(prev_build.units_new))
    return
end
