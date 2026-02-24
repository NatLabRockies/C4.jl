const TechnologyExpansion = Union{
    ThermalExpansion,VariableExpansion,StorageExpansion
}
name(tech::TechnologyExpansion) = name(tech.params)

function warmstart_builds!(
    build::T, prev_build::T
) where {T <: TechnologyExpansion}
    warmstart_builds!.(build.sites, prev_build.sites)
    return
end

struct InterfaceExpansion <: Interface

    params::InterfaceParams
    capacity_new::JuMP.VariableRef

    function InterfaceExpansion(m::JuMP.Model, params::InterfaceParams)

        capacity_new = @variable(m, lower_bound=0,
                                    upper_bound=params.capacity_new_max)
        JuMP.set_name(capacity_new, "iface_capacity_new[$(params.name)]")

        return new(params, capacity_new)

    end

end

name(iface::InterfaceExpansion) = name(iface.params)
availablecapacity(iface::InterfaceExpansion) = availablecapacity(iface.params) + iface.capacity_new
cost(build::InterfaceExpansion) = build.capacity_new * build.params.cost_capital

region_from(iface::InterfaceExpansion) = region_from(iface.params)
region_to(iface::InterfaceExpansion) = region_to(iface.params)

function InterfaceParams(build::InterfaceExpansion)
    iface = build.params
    new_capacity = value(build.capacity_new)
    return InterfaceParams(
        iface.name, iface.region_from, iface.region_to, iface.cost_capital,
        iface.capacity_existing + new_capacity,
        iface.capacity_new_max - new_capacity)
end

function warmstart_builds!(build::InterfaceExpansion, prev_build::InterfaceExpansion)
    JuMP.set_start_value(build.capacity_new, value(prev_build.capacity_new))
    return
end

struct RegionExpansion <: Region{InterfaceExpansion}

    params::RegionParams

    thermaltechs::Vector{ThermalExpansion}
    variabletechs::Vector{VariableExpansion}
    storagetechs::Vector{StorageExpansion}

    function RegionExpansion(m::JuMP.Model, regionparams::RegionParams)

        thermaltechs = [ThermalExpansion(m, techparams, regionparams)
                        for techparams in regionparams.thermaltechs_candidate]

        variabletechs = [VariableExpansion(m, techparams, regionparams)
                        for techparams in regionparams.variabletechs_candidate]

        storagetechs = [StorageExpansion(m, techparams, regionparams)
                        for techparams in regionparams.storagetechs_candidate]

        new(regionparams, thermaltechs, variabletechs, storagetechs)

    end

end

name(region::RegionExpansion) = region.params.name
demand(region::RegionExpansion, t::Int) = demand(region.params, t)

importinginterfaces(region::RegionExpansion) = importinginterfaces(region.params)
exportinginterfaces(region::RegionExpansion) = exportinginterfaces(region.params)

cost(build::RegionExpansion) =
    sum(cost(thermaltech) for thermaltech in build.thermaltechs; init=0) +
    sum(cost(variabletech) for variabletech in build.variabletechs; init=0) +
    sum(cost(storagetech) for storagetech in build.storagetechs; init=0)

thermaltechs(region::RegionExpansion) =
    [region.thermaltechs; region.params.thermaltechs_existing]

variabletechs(region::RegionExpansion) =
    [region.variabletechs; region.params.variabletechs_existing]

storagetechs(region::RegionExpansion) =
    [region.storagetechs; region.params.storagetechs_existing]

function RegionParams(build::RegionExpansion)

    region = build.params

    thermal_existing = vcat(
            [ThermalExistingParams(tech)
             for tech in build.thermaltechs
             if value(nameplatecapacity(tech)) > 0],
            region.thermaltechs_existing)

    variable_existing = vcat(
            [VariableExistingParams(tech)
             for tech in build.variabletechs
             if value(nameplatecapacity(tech)) > 0],
            region.variabletechs_existing)

    # We leave in all storage resources (whether built or not)
    # in order to simplify extracting marginal EUE reductions from
    # PRAS results later
    storage_existing = vcat(
            [StorageExistingParams(tech) for tech in build.storagetechs],
            region.storagetechs_existing)

    return RegionParams(
        region.name, region.demand,
        thermal_existing,
        ThermalCandidateParams.(build.thermaltechs),
        variable_existing,
        VariableCandidateParams.(build.variabletechs),
        storage_existing,
        StorageCandidateParams.(build.storagetechs),
        region.export_interfaces, region.import_interfaces)
end

function warmstart_builds!(build::RegionExpansion, prev_build::RegionExpansion)
    warmstart_builds!.(build.thermaltechs, prev_build.thermaltechs)
    warmstart_builds!.(build.variabletechs, prev_build.variabletechs)
    warmstart_builds!.(build.storagetechs, prev_build.storagetechs)
    return
end

struct SystemExpansion <: System{RegionExpansion, InterfaceExpansion}
     regions::Vector{RegionExpansion}
     interfaces::Vector{InterfaceExpansion}
end

cost(builds::SystemExpansion) =
    sum(cost(region) for region in builds.regions; init=0) +
    sum(cost(interface) for interface in builds.interfaces; init=0)
