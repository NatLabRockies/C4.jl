struct FuelParams
    name::String
    cost::Float64 # $/MMBtu
    co2_factor::Float64 # Megatonnes/MMBtu
end

struct ThermalExistingSiteParams

    name::String

    units::Int

    rating::Vector{Float64}

    λ::Vector{Float64}
    μ::Vector{Float64}

end

availability(site::ThermalExistingSiteParams, t::Int) =
    site.rating[t] * site.μ[t] / (site.λ[t] + site.μ[t])

struct ThermalExistingParams <: ThermalTechnology

    name::String
    category::String

    fuel::FuelParams
    heat_rate::Float64 # MMBtu/MWh
    startup_heat::Float64 # MMBtu/start

    cost_vom::Float64 # $/MWh

    unit_size::Float64 # MW/unit
    min_gen::Float64 # MW/unit
    max_ramp::Float64 # MW/hour
    min_uptime::Int # hours
    min_downtime::Int # hours

    sites::Vector{ThermalExistingSiteParams}

end

nameplatecapacity(tech::ThermalExistingParams) =
    tech.unit_size * sum(site.units for site in tech.sites; init=0)

availablecapacity(tech::ThermalExistingParams, t::Int) =
    tech.unit_size * sum(site.units * availability(site, t) for site in tech.sites; init=0)

cost_startup(tech::ThermalExistingParams) =
    tech.startup_heat * tech.fuel.cost

cost_generation(tech::ThermalExistingParams) =
    tech.heat_rate * tech.fuel.cost + tech.cost_vom

co2_startup(tech::ThermalExistingParams) =
    tech.startup_heat * tech.fuel.co2_factor

co2_generation(tech::ThermalExistingParams) =
    tech.heat_rate * tech.fuel.co2_factor

max_unit_ramp(tech::ThermalExistingParams) = tech.max_ramp

num_units(tech::ThermalExistingParams) = sum(site.units for site in tech.sites; init=0)

unit_size(tech::ThermalExistingParams) = tech.unit_size

min_gen(tech::ThermalExistingParams) = tech.min_gen

min_uptime(tech::ThermalExistingParams) = tech.min_uptime

min_downtime(tech::ThermalExistingParams) = tech.min_downtime

struct ThermalCandidateParams

    name::String
    category::String

    fuel::FuelParams
    heat_rate::Float64 # MMBtu/MWh
    startup_heat::Float64 # MMBtu/start

    cost_vom::Float64 # $/MWh
    cost_capital::Float64 # annualized $/MW

    max_units::Int

    unit_size::Float64 # MW/unit
    min_gen::Float64 # MW/unit
    max_ramp::Float64 # MW/hour
    min_uptime::Int # hours
    min_downtime::Int # hours

    rating::Vector{Float64}

    λ::Vector{Float64}
    μ::Vector{Float64}

end

cost_generation(tech::ThermalCandidateParams) =
    tech.heat_rate * tech.fuel.cost + tech.cost_vom

co2_generation(tech::ThermalCandidateParams) =
    tech.heat_rate * tech.fuel.co2_factor

availability(params::ThermalCandidateParams, t::Int) =
    params.rating[t] * params.μ[t] / (params.λ[t] + params.μ[t])
