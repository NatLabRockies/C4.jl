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

    cost_generation::Float64 # $/MWh
    cost_startup::Float64 # $/start

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

cost_generation(tech::ThermalExistingParams) = tech.cost_generation

max_unit_ramp(tech::ThermalExistingParams) = tech.max_ramp

num_units(tech::ThermalExistingParams) = sum(site.units for site in tech.sites; init=0)

unit_size(tech::ThermalExistingParams) = tech.unit_size

min_gen(tech::ThermalExistingParams) = tech.min_gen
struct ThermalCandidateParams

    name::String
    category::String

    cost_generation::Float64 # $/MWh
    cost_startup::Float64 # $/start
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

availability(params::ThermalCandidateParams, t::Int) =
    params.rating[t] * params.μ[t] / (params.λ[t] + params.μ[t])
