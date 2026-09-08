struct StorageExistingSiteParams
    name::String
    capacity::InvestmentDataArray{Float64} # MW
end

struct StorageExistingParams <: DispatchableStorageTech

    name::String
    category::String

    duration::InvestmentDataArray{Float64} # hours
    roundtrip_efficiency::Float64

    cost_vom::InvestmentDataArray{Float64} # $/MWh
    cost_fom_power::InvestmentDataArray{Float64} # $/MWh
    cost_fom_energy::InvestmentDataArray{Float64} # $/MWh

    sites::Vector{StorageExistingSiteParams}

end

tech(::Type{StorageExistingSiteParams}) = StorageExistingParams

maxpower(tech::StorageExistingParams, i::Int) =
    sum(site.capacity[i] for site in tech.sites; init=0)

maxenergy(tech::StorageExistingParams, i::Int) = maxpower(tech, i) * tech.duration[i]

roundtrip_efficiency(tech::StorageExistingParams) = tech.roundtrip_efficiency

operating_cost(tech::StorageExistingParams, i::Int) = tech.cost_vom[i]

cost_fom_power(tech::StorageExistingParams, invyear::Int) = tech.cost_fom_power[invyear]
cost_fom_energy(tech::StorageExistingParams, invyear::Int) = tech.cost_fom_energy[invyear]

struct StorageCandidateParams

    name::String
    category::String

    roundtrip_efficiency::Float64
    duration_min::Float64 # h
    duration_max::Float64 # h

    cost_vom::InvestmentDataArray{Float64} # $/MWh
    cost_fom_power::InvestmentDataArray{Float64} # $/MWh
    cost_fom_energy::InvestmentDataArray{Float64} # $/MWh
    cost_overnightcapital_power::InvestmentDataArray{Float64} # annualized $/MW
    cost_overnightcapital_energy::InvestmentDataArray{Float64} # annualized $/MWh

    capital_recovery_period::Int # years

    power_max::InvestmentDataArray{Float64} # MW
    energy_max::InvestmentDataArray{Float64} # MWh

end

operating_cost(tech::StorageCandidateParams, i::Int) = tech.cost_vom[i]

cost_fom_power(tech::StorageCandidateParams, invyear::Int) = tech.cost_fom_power[invyear]
cost_fom_energy(tech::StorageCandidateParams, invyear::Int) = tech.cost_fom_energy[invyear]

cost_capex_power(tech::StorageCandidateParams, invyear::Int, wacc::Float64) =
    tech.cost_overnightcapital_power[invyear] *
    financing_factor(wacc, tech.capital_recovery_period)

cost_capex_energy(tech::StorageCandidateParams, invyear::Int, wacc::Float64) =
    tech.cost_overnightcapital_energy[invyear] *
    financing_factor(wacc, tech.capital_recovery_period)
