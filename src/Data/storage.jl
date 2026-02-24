struct StorageExistingSiteParams
    name::String
    power::Float64 # MW
end

struct StorageExistingParams <: StorageTechnology

    name::String
    category::String

    cost_operation::Float64 # $/MWh
    roundtrip_efficiency::Float64

    duration::Float64 # hours

    sites::Vector{StorageExistingSiteParams}

end

maxpower(tech::StorageExistingParams) =
    sum(site.power for site in tech.sites; init=0)

maxenergy(tech::StorageExistingParams) = maxpower(tech) * tech.duration

roundtrip_efficiency(tech::StorageExistingParams) = tech.roundtrip_efficiency

operating_cost(tech::StorageExistingParams) = tech.cost_operation

struct StorageCandidateParams

    name::String
    category::String

    cost_operation::Float64 # $/MWh
    roundtrip_efficiency::Float64

    cost_capital_power::Float64 # annualized $/MW

    power_max::Float64 # MW
    duration::Float64 # h

end
