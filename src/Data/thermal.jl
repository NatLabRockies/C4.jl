struct FuelParams
    name::String
    cost::InvestmentDataArray{Float64} # $/MMBtu
    co2_factor::Float64 # tonnes/MMBtu
end

struct ThermalExistingSiteParams

    name::String

    units::InvestmentDataArray{Int}

    λ::DispatchDataArray{Float64}
    μ::DispatchDataArray{Float64}

end

availability(site::ThermalExistingSiteParams, i::Int, d::Int, h::Int) =
    site.μ[h, d, i] / (site.λ[h, d, i] + site.μ[h, d, i])

struct ThermalExistingParams <: DispatchableThermalTech

    name::String
    category::String

    fuel::FuelParams
    heat_rate::Float64 # MMBtu/MWh
    startup_heat::Float64 # MMBtu/start

    cost_vom::InvestmentDataArray{Float64} # $/MWh
    cost_fom::InvestmentDataArray{Float64} # $/MWh

    unit_size::Float64 # MW/unit
    rating::DispatchDataArray{Float64}

    min_gen::Float64 # MW/unit
    max_ramp::Float64 # MW/hour
    min_uptime::Int # hours
    min_downtime::Int # hours

    sites::Vector{ThermalExistingSiteParams}

end

tech(::Type{ThermalExistingSiteParams}) = ThermalExistingParams

nameplatecapacity(tech::ThermalExistingParams, invyear::Int) =
    tech.unit_size * sum(site.units[invyear] for site in tech.sites; init=0)

ratedcapacity(tech::ThermalExistingParams, invyear::Int, day::Int, hour::Int) =
    nameplatecapacity(tech, invyear) * tech.rating[invyear, day, hour]

expectedcapacity(tech::ThermalExistingParams, invyear::Int, day::Int, hour::Int) =
    tech.rating[invyear, day, hour] * tech.unit_size * sum(
        site.units[invyear] * availability(site, invyear, day, hour)
        for site in tech.sites; init=0)

cost_startup(tech::ThermalExistingParams, invyear::Int) =
    tech.startup_heat * tech.fuel.cost[invyear]

cost_generation(tech::ThermalExistingParams, invyear::Int) =
    tech.heat_rate * tech.fuel.cost[invyear] + tech.cost_vom[invyear]

co2_startup(tech::ThermalExistingParams) =
    tech.startup_heat * tech.fuel.co2_factor

co2_generation(tech::ThermalExistingParams) =
    tech.heat_rate * tech.fuel.co2_factor

num_units(tech::ThermalExistingParams, invyear::Int) =
    sum(site.units[invyear] for site in tech.sites; init=0)

unit_size(tech::ThermalExistingParams) = tech.unit_size

min_gen(tech::ThermalExistingParams) = tech.min_gen
max_unit_ramp(tech::ThermalExistingParams) = tech.max_ramp
min_uptime(tech::ThermalExistingParams) = tech.min_uptime
min_downtime(tech::ThermalExistingParams) = tech.min_downtime

struct ThermalCandidateParams

    name::String
    category::String

    fuel::FuelParams
    heat_rate::Float64 # MMBtu/MWh
    startup_heat::Float64 # MMBtu/start

    cost_vom::InvestmentDataArray{Float64} # $/MWh
    cost_fom::InvestmentDataArray{Float64} # $/MW
    cost_overnightcapital::InvestmentDataArray{Float64} # $/MW

    capital_recovery_period::Float64 # years

    max_units::InvestmentDataArray{Int}

    unit_size::Float64 # MW/unit
    rating::DispatchDataArray{Float64}

    min_gen::Float64 # MW/unit
    max_ramp::Float64 # MW/hour
    min_uptime::Int # hours
    min_downtime::Int # hours

    λ::DispatchDataArray{Float64}
    μ::DispatchDataArray{Float64}

end

cost_startup(tech::ThermalCandidateParams, invyear::Int) =
    tech.startup_heat * tech.fuel.cost[invyear]

cost_generation(tech::ThermalCandidateParams, invyear::Int) =
    tech.heat_rate * tech.fuel.cost[invyear] + tech.cost_vom[invyear]

cost_capex(tech::ThermalCandidateParams, invyear::Int, wacc::Float64) =
    tech.cost_overnightcapital[invyear] *
    financing_factor(wacc, tech.capital_recovery_period)

co2_startup(tech::ThermalCandidateParams) =
    tech.startup_heat * tech.fuel.co2_factor

co2_generation(tech::ThermalCandidateParams) =
    tech.heat_rate * tech.fuel.co2_factor

availability(params::ThermalCandidateParams, i::Int, d::Int, h::Int) =
    params.μ[h, d, i] / (params.λ[h, d, i] + params.μ[h, d, i])
