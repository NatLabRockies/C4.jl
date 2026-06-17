const SiteParams = Union{
    ThermalExistingSiteParams,
    VariableExistingSiteParams, VariableCandidateSiteParams,
    StorageExistingSiteParams
}

name(site::SiteParams) = site.name

const TechnologyParams = Union{
    ThermalExistingParams, ThermalCandidateParams,
    VariableExistingParams, VariableCandidateParams,
    StorageExistingParams, StorageCandidateParams
}

name(tech::TechnologyParams) = tech.name

const EntityParams = Union{TechnologyParams, SiteParams, FuelParams}

struct SystemParams <: DispatchableSystem

    name::String

    times::TimeIndices

    demand::DispatchDataArray{Float64}

    fuels::Vector{FuelParams}

    thermaltechs_existing::Vector{ThermalExistingParams}
    thermaltechs_candidate::Vector{ThermalCandidateParams}

    variabletechs_existing::Vector{VariableExistingParams}
    variabletechs_candidate::Vector{VariableCandidateParams}

    storagetechs_existing::Vector{StorageExistingParams}
    storagetechs_candidate::Vector{StorageCandidateParams}

end

name(sys::SystemParams) = sys.name

demand(sys::SystemParams, invyear::Int, day::Int, hour::Int) =
    sys.demand[hour, day, invyear]

total_demand(sys::SystemParams, invyear::Int=1) = sum(sys.demand[:, :, invyear])

thermaltechs(sys::SystemParams) = sys.thermaltechs_existing
variabletechs(sys::SystemParams) = sys.variabletechs_existing
storagetechs(sys::SystemParams) = sys.storagetechs_existing

techs(sys::SystemParams, ::Type{ThermalExistingParams}) =
    sys.thermaltechs_existing

techs(sys::SystemParams, ::Type{ThermalCandidateParams}) =
    sys.thermaltechs_candidate

techs(sys::SystemParams, ::Type{VariableCandidateParams}) =
    sys.variabletechs_candidate

techs(sys::SystemParams, ::Type{VariableExistingParams}) =
    sys.variabletechs_existing

techs(sys::SystemParams, ::Type{StorageExistingParams}) =
    sys.storagetechs_existing

techs(sys::SystemParams, ::Type{StorageCandidateParams}) =
    sys.storagetechs_candidate

sites(sys::SystemParams, sitetype::Type{<:SiteParams}) =
    [site for tech in techs(sys, tech(sitetype)) for site in tech.sites]

function get_entity(sys::SystemParams, entitytype::Type{<:EntityParams}, name::String)
    vals = entities(sys, entitytype)
    i = findfirst(x -> x.name == name, vals)
    isnothing(i) && error("Could not find entity with name $name")
    return i, vals[i]
end

entitynames(sys::SystemParams, entitytype::Type{<:EntityParams}) =
    Set(entity.name for entity in entities(sys, entitytype))

entities(sys::SystemParams, ::Type{FuelParams}) = sys.fuels

entities(sys::SystemParams, techtype::Type{<:TechnologyParams}) =
    techs(sys,  techtype)

entities(sys::SystemParams, sitetype::Type{<:SiteParams}) =
    sites(sys,  sitetype)

# TODO - Show multi-investment-period data
function Base.show(io::IO, ::MIME"text/plain", sys::SystemParams)

    println(io, "SystemParams for ", sys.name)

    n_invyears = length(sys.times.investment_years)
    n_dispatchyears = length(sys.times.dispatch_daycount)
    println(io, n_invyears, " investment years each with ",
            n_dispatchyears, " dispatch years")
    println(io, "(only showing first investment year here)")

    peak_load = maximum(sys.demand[:,:,1]) * powerunits_MW
    println(io, "Peak Load: ", peak_load, " MW")

    has_thermal = length(sys.thermaltechs_existing) > 0
    has_variable = length(sys.variabletechs_existing) > 0
    has_storage = length(sys.storagetechs_existing) > 0

    has_thermal || has_variable || has_storage || println(io, "\t(No resources)")

    for thermaltech in sys.thermaltechs_existing
        println(io, "\t", thermaltech.name, ":")
        for site in thermaltech.sites
            println(io, "\t\t", site.name, ": ",
                    site.units[1], " x ", thermaltech.unit_size * powerunits_MW, " MW")
        end
    end

    for variabletech in sys.variabletechs_existing
        capacity = nameplatecapacity(variabletech)
        iszero(capacity) && continue
        println(io, "\t", variabletech.name, ": ", capacity * powerunits_MW, " MW")
    end

    for storagetech in sys.storagetechs_existing
        power, energy = maxpower(storagetech), maxenergy(storagetech)
        iszero(power) && continue
        println(io, "\t", storagetech.name, ": ",
                power * powerunits_MW, " MW (", energy / power, " h)")
    end

end
