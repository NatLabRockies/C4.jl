struct SystemParams <: System

    name::String

    timesteps::StepRange{DateTime,Hour}

    demand::Vector{Float64}

    fuels::Vector{FuelParams}

    thermaltechs_existing::Vector{ThermalExistingParams}
    thermaltechs_candidate::Vector{ThermalCandidateParams}

    variabletechs_existing::Vector{VariableExistingParams}
    variabletechs_candidate::Vector{VariableCandidateParams}

    storagetechs_existing::Vector{StorageExistingParams}
    storagetechs_candidate::Vector{StorageCandidateParams}

end

name(sys::SystemParams) = sys.name
demand(sys::SystemParams, t::Int) = sys.demand[t]
total_demand(sys::SystemParams) = sum(sys.demand)

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

get_tech(
    sys::SystemParams,
    techtype::Type{<:TechnologyParams},
    techname::String
) = last(getbyname(techs(sys, techtype), techname))

techset(system::SystemParams, techtype::Type{<:TechnologyParams}) =
    Set(tech.name for tech in techs(system, techtype))

function get_site(
    system::SystemParams,
    techtype::Type{<:TechnologyParams},
    techname::String,
    sitename::String
)

    tech = get_tech(system, techtype, techname)
    return last(getbyname(tech.sites, sitename))

end

function techsiteset(system::SystemParams, techtype::Type{<:TechnologyParams})
    result = Set{Tuple{String,String}}()
    for tech in techs(system, techtype)
        for site in tech.sites
            push!(result, (tech.name, site.name))
        end
    end
    return result
end

function getbyname(vals::Vector{T}, name::String) where T
    i = findfirst(x -> x.name == name, vals)
    isnothing(i) && error("Could not find entity with name $name")
    return i, vals[i]
end

function daycount(sys::SystemParams, daylength::Int)
    n_periods = length(sys.timesteps)
    n_days, remainder = divrem(n_periods, daylength)
    iszero(remainder) ||
        error("SystemParams timesteps ($(n_periods)) should be a multiple of daylength ($(daylength))")
    return n_days
end

function Base.show(io::IO, ::MIME"text/plain", sys::SystemParams)

    println(io, "SystemParams for ", sys.name)
    println(io, first(sys.timesteps), " -> ", last(sys.timesteps))
    println(io, "Peak Load: ", maximum(sys.demand) * powerunits_MW, " MW")

    has_thermal = length(sys.thermaltechs_existing) > 0
    has_variable = length(sys.variabletechs_existing) > 0
    has_storage = length(sys.storagetechs_existing) > 0

    has_thermal || has_variable || has_storage || println(io, "\t(No resources)")

    for thermaltech in sys.thermaltechs_existing
        println(io, "\t", thermaltech.name, ":")
        for site in thermaltech.sites
            println(io, "\t\t", site.name, ": ",
                    site.units, " x ", thermaltech.unit_size * powerunits_MW, " MW")
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
