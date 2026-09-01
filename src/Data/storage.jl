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

struct StorageCandidateParams

    name::String
    category::String

    roundtrip_efficiency::Float64

    cost_vom::InvestmentDataArray{Float64} # $/MWh
    cost_fom_power::InvestmentDataArray{Float64} # $/MWh
    cost_fom_energy::InvestmentDataArray{Float64} # $/MWh
    cost_overnightcapital_power::InvestmentDataArray{Float64} # annualized $/MW
    cost_overnightcapital_energy::InvestmentDataArray{Float64} # annualized $/MWh

    capital_recovery_period::Float64 # years

    power_max::InvestmentDataArray{Float64} # MW
    energy_max::InvestmentDataArray{Float64} # MWh
    # could do a duration_max too?

end

cost_capex_power(tech::StorageCandidateParams, invyear::Int, wacc::Float64) =
    tech.cost_overnightcapital_power[invyear] *
    financing_factor(wacc, tech.capital_recovery_period)

cost_capex_energy(tech::StorageCandidateParams, invyear::Int, wacc::Float64) =
    tech.cost_overnightcapital_energy[invyear] *
    financing_factor(wacc, tech.capital_recovery_period)
