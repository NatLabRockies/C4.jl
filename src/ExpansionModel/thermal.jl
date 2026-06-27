struct ThermalExpansion <: DispatchableThermalTech

    params::ThermalCandidateParams
    units_new::Vector{JuMP.VariableRef}

    function ThermalExpansion(
        m::JuMP.Model, techparams::ThermalCandidateParams, times::TimeIndices)

        n_invyears = length(times.investment_years)

        units_new = @variable(m, [1:n_invyears], integer=true, lower_bound=0)
        set_upper_bound.(units_new, techparams.max_units)
        varnames!(units_new, "thermal_new_units[$(techparams.name)]",
                  times.investment_years)

        new(techparams, units_new)

    end

end

nameplatecapacity(tech::ThermalExpansion, i::Int=1) =
        sum(tech.units_new[1:i]) * tech.params.unit_size

ratedcapacity(tech::ThermalExpansion, invyear::Int, day::Int, hour::Int) =
    nameplatecapacity(tech, invyear) * tech.params.rating[hour, day, invyear]

expectedcapacity(tech::ThermalExpansion, invyear::Int, day::Int, hour::Int) =
    ratedcapacity(tech, invyear) * availability(tech.params, invyear, day, hour)

cost(build::ThermalExpansion, invyear::Int=1) =
    build.units_new[invyear] * build.params.unit_size * build.params.cost_capital[invyear]

cost_startup(build::ThermalExpansion, invyear::Int=1) =
    cost_startup(build.params, invyear)

cost_generation(tech::ThermalExpansion, invyear::Int=1) =
    cost_generation(tech.params, invyear)

co2_startup(build::ThermalExpansion) = co2_startup(build.params)
co2_generation(tech::ThermalExpansion) = co2_generation(tech.params)

num_units(tech::ThermalExpansion, i::Int=1) = tech.units_new[i]

unit_size(tech::ThermalExpansion) = tech.params.unit_size

min_gen(tech::ThermalExpansion) = tech.params.min_gen
max_unit_ramp(tech::ThermalExpansion) = tech.params.max_ramp
min_uptime(tech::ThermalExpansion) = tech.params.min_uptime
min_downtime(tech::ThermalExpansion) = tech.params.min_downtime

function ThermalExistingParams(tech::ThermalExpansion)

    params = tech.params

    new_site = ThermalExistingSiteParams(
        "",
        cumsum(round.(Int, value.(tech.units_new))),
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

    params = tech.params

    return ThermalCandidateParams(
        params.name,
        params.category,
        params.fuel,
        params.heat_rate,
        params.startup_heat,
        params.cost_vom,
        params.cost_capital,
        params.max_units .- round.(Int, value.(tech.units_new)),
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
    JuMP.set_start_value.(build.units_new, value.(prev_build.units_new))
    return
end
