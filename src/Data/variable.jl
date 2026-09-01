struct VariableExistingSiteParams <: DispatchableVariableSite

    name::String

    capacity::InvestmentDataArray{Float64} # MW
    availability::DispatchDataArray{Float64}

end

nameplatecapacity(site::VariableExistingSiteParams, invyear::Int) =
    site.capacity[invyear]

availability(site::VariableExistingSiteParams, invyear::Int, day::Int, hour::Int) =
    site.availability[hour, day, invyear]

struct VariableExistingParams <: DispatchableVariableTech

    name::String
    category::String

    cost_vom::InvestmentDataArray{Float64} # $/MWh
    cost_fom::InvestmentDataArray{Float64} # $/MWh

    sites::Vector{VariableExistingSiteParams}

end

tech(::Type{VariableExistingSiteParams}) = VariableExistingParams

sites(tech::VariableExistingParams) = tech.sites
cost_generation(tech::VariableExistingParams, invyear::Int) = tech.cost_vom[invyear]
name(tech::VariableExistingParams) = tech.name

struct VariableCandidateSiteParams

    name::String

    capacity_max::InvestmentDataArray{Float64} # MW
    availability::DispatchDataArray{Float64}

end

name(site::VariableCandidateSiteParams) = site.name

struct VariableCandidateParams

    name::String
    category::String

    cost_overnightcapital::InvestmentDataArray{Float64} # annualized $/MW
    cost_vom::InvestmentDataArray{Float64} # $/MWh
    cost_fom::InvestmentDataArray{Float64} # $/MWh

    capital_recovery_period::Float64 # years

    sites::Vector{VariableCandidateSiteParams}

end

cost_capex(tech::VariableCandidateParams, invyear::Int, wacc::Float64) =
    tech.cost_overnightcapital[invyear] *
    financing_factor(wacc, tech.capital_recovery_period)

tech(::Type{VariableCandidateSiteParams}) = VariableCandidateParams
