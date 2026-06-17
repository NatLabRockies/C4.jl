struct ThermalExpansion <: DispatchableThermalTech

    params::ThermalCandidateParams
    units_new::JuMP.VariableRef

    function ThermalExpansion(
        m::JuMP.Model, techparams::ThermalCandidateParams)

        units_new = @variable(m, integer=true, lower_bound=0,
                              upper_bound=techparams.max_units[1])
        JuMP.set_name(units_new, "thermal_new_units[$(techparams.name)]")

        new(techparams, units_new)

    end

end

nameplatecapacity(tech::ThermalExpansion) =
        tech.units_new * tech.params.unit_size

ratedcapacity(tech::ThermalExpansion, invyear::Int, day::Int, hour::Int) =
    nameplatecapacity(tech, invyear) * tech.params.rating[invyear, day, hour]

expectedcapacity(tech::ThermalExistingParams, invyear::Int, day::Int, hour::Int) =
    rated(tech, invyear) * availability(tech.params, invyear, day, hour)

cost(build::ThermalExpansion, invyear::Int=1) =
    build.units_new * build.params.unit_size * build.params.cost_capital[invyear]

cost_startup(build::ThermalExpansion, invyear::Int=1) =
    cost_startup(build.params)

cost_generation(tech::ThermalExpansion, invyear::Int=1) =
    cost_generation(tech.params)

co2_startup(build::ThermalExpansion) = co2_startup(build.params)
co2_generation(tech::ThermalExpansion) = co2_generation(tech.params)

num_units(tech::ThermalExpansion) = tech.units_new

unit_size(tech::ThermalExpansion) = tech.params.unit_size

min_gen(tech::ThermalExpansion) = tech.params.min_gen
max_unit_ramp(tech::ThermalExpansion) = tech.params.max_ramp
min_uptime(tech::ThermalExpansion) = tech.params.min_uptime
min_downtime(tech::ThermalExpansion) = tech.params.min_downtime

function ThermalExistingParams(tech::ThermalExpansion)

    new_units = round(Int, value(tech.units_new))
    params = tech.params

    new_site = ThermalExistingSiteParams(
        "",
        [new_units],
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
        params.rating,
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
        [params.max_units[1] - new_units],
        params.unit_size,
        params.rating,
        params.min_gen,
        params.max_ramp,
        params.min_uptime,
        params.min_downtime,
        params.λ,
        params.μ)

end

function warmstart_builds!(build::ThermalExpansion, prev_build::ThermalExpansion)
    JuMP.set_start_value(build.units_new, value(prev_build.units_new))
    return
end
