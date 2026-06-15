struct ThermalDispatch{G<:ThermalTechnology}

    dispatch::Vector{JuMP.VariableRef}
    dispatch_max::Vector{JuMP_LessThanConstraintRef}

    tech::G

    function ThermalDispatch(
        m::JuMP.Model, region::Region,
        tech::G, period::TimePeriod
    ) where G <: ThermalTechnology

        T = length(period)
        ts = period.timesteps

        dispatch = @variable(m, [1:T], lower_bound = 0)
        fullname = join([name(region), name(tech), period.name], ",")
        varnames!(dispatch, "tech_dispatch[$(fullname)]", 1:T)

        dispatch_max = @constraint(m, [t in 1:T],
            dispatch[t] <= nameplatecapacity(tech))

        return new{G}(dispatch, dispatch_max, tech)

    end

end

cost(dispatch::ThermalDispatch) =
    sum(dispatch.dispatch) * cost_generation(dispatch.tech)

name(dispatch::ThermalDispatch) = name(dispatch.tech)

struct StorageDispatch{S<:StorageTechnology}

    charge::Vector{JuMP.VariableRef}
    discharge::Vector{JuMP.VariableRef}
    dispatch::Vector{JuMP_ExpressionRef}

    charge_max::Vector{JuMP_LessThanConstraintRef}
    discharge_max::Vector{JuMP_LessThanConstraintRef}

    e_net::JuMP.VariableRef # MWh
    e_net_def::JuMP_EqualToConstraintRef

    e_high::JuMP.VariableRef # MWh
    e_high_def::Vector{JuMP_LessThanConstraintRef}

    e_low::JuMP.VariableRef # MWh
    e_low_def::Vector{JuMP_LessThanConstraintRef}

    stor::S

    function StorageDispatch(
        m::JuMP.Model, region::Region, stor::S,
        period::TimePeriod) where S <: StorageTechnology

        T = length(period)

        charge = @variable(m, [1:T], lower_bound = 0)
        fullname = join([name(region), name(stor), period.name], ",")
        varnames!(charge, "stor_charge[$(fullname)]", 1:T)

        discharge = @variable(m, [1:T], lower_bound = 0)
        fullname = join([name(region), name(stor), period.name], ",")
        varnames!(discharge, "stor_discharge[$(fullname)]", 1:T)

        capacity = maxpower(stor)
        eff = sqrt(roundtrip_efficiency(stor))

        charge_max = @constraint(m, [t in 1:T], charge[t] <= capacity)
        discharge_max = @constraint(m, [t in 1:T], discharge[t] <= capacity)

        e_net = @variable(m)
        e_net_def = @constraint(m, e_net == eff * sum(charge) - 1/eff * sum(discharge))

        e_high = @variable(m, base_name="stor_ΔE_high[$(fullname)]")
        e_high_def = @constraint(m, [t in 1:T],
            eff * sum(charge[1:t]) - 1/eff * sum(discharge[1:t]) <= e_high)

        e_low = @variable(m, base_name="stor_ΔE_low[$(fullname)]")
        e_low_def = @constraint(m, [t in 1:T],
            e_low <= eff * sum(charge[1:t]) - 1/eff * sum(discharge[1:t]))
        dispatch = @expression(m, [t in 1:T], discharge[t] - charge[t])

        return new{S}(
            charge, discharge, dispatch, charge_max, discharge_max,
            e_net, e_net_def, e_high, e_high_def, e_low, e_low_def,
            stor)

    end

end

name(dispatch::StorageDispatch) =
    name(dispatch.stor)

usage(dispatch::StorageDispatch) =
    sum(dispatch.charge) + sum(dispatch.discharge)

cost(dispatch::StorageDispatch) =
    usage(dispatch) * operating_cost(dispatch.stor)

struct VariableDispatch{V<:VariableTechnology}

    dispatch::Vector{JuMP.VariableRef}
    dispatch_max::Vector{JuMP_LessThanConstraintRef}

    tech::V

    function VariableDispatch(
        m::JuMP.Model, region::Region,
        tech::V, period::TimePeriod
    ) where V <: VariableTechnology

        T = length(period)
        ts = period.timesteps

        dispatch = @variable(m, [1:T], lower_bound = 0)
        fullname = join([name(region), name(tech), period.name], ",")
        varnames!(dispatch, "tech_dispatch[$(fullname)]", 1:T)

        dispatch_max = @constraint(m, [t in 1:T],
            dispatch[t] <= availablecapacity(tech, ts[t]))

        return new{V}(dispatch, dispatch_max, tech)

    end

end

cost(dispatch::VariableDispatch) =
    sum(dispatch.dispatch) * cost_generation(dispatch.tech)

# TODO: Where is this used?
name(dispatch::VariableDispatch) = name(dispatch.tech)

struct InterfaceDispatch{I<:Interface}

    flow::Vector{JuMP.VariableRef}

    flow_min::Vector{JuMP_GreaterThanConstraintRef}
    flow_max::Vector{JuMP_LessThanConstraintRef}

    iface::I

    function InterfaceDispatch(
        m::JuMP.Model, iface::I, period::TimePeriod) where I <: Interface

        T = length(period)

        flow = @variable(m, [1:T])
        varnames!(flow, "iface_flow[$(name(iface)),$(period.name)]", 1:T)

        capacity = availablecapacity(iface)
        flow_min = @constraint(m, [t in 1:T], flow[t] >= -capacity)
        flow_max = @constraint(m, [t in 1:T], flow[t] <= capacity)

        return new{I}(flow, flow_min, flow_max, iface)

    end

end

region_from(iface::InterfaceDispatch) = region_from(iface.iface)
region_to(iface::InterfaceDispatch) = region_to(iface.iface)

struct RegionDispatch{R<:Region, I<:Interface}

     # Note these vectors are heterogenously typed
    thermaltechs::Vector{ThermalDispatch}
    variabletechs::Vector{VariableDispatch}
    storagetechs::Vector{StorageDispatch}

    netload::Vector{JuMP_ExpressionRef}
    unserved_energy::Union{Vector{JuMP.VariableRef},Nothing}
    voll::Float64

    import_interfaces::Vector{InterfaceDispatch{I}}
    export_interfaces::Vector{InterfaceDispatch{I}}

    region::R

    function RegionDispatch(
        m::JuMP.Model,
        region::R,
        interfaces::Vector{InterfaceDispatch{I}},
        period::TimePeriod, voll::Float64
    ) where {I, R<:Region{I} }

        T = length(period)
        ts = period.timesteps

        thermaldispatch = [ThermalDispatch(m, region, tech, period)
                           for tech in thermaltechs(region)]

        variabledispatch = [VariableDispatch(m, region, tech, period)
                            for tech in variabletechs(region)]

        storagedispatch = [StorageDispatch(m, region, tech, period)
                           for tech in storagetechs(region)]

        unserved_energy = isnan(voll) ? nothing : @variable(m, [1:T], lower_bound=0)

        netload = @expression(m, [t in 1:T],
                demand(region, ts[t])
                - sum(gen.dispatch[t] for gen in thermaldispatch)
                - sum(gen.dispatch[t] for gen in variabledispatch)
                - sum(stor.dispatch[t] for stor in storagedispatch)
                - (isnan(voll) ? 0 : unserved_energy[t]))

        import_interfaces = [interfaces[i] for i in importinginterfaces(region)]
        export_interfaces = [interfaces[i] for i in exportinginterfaces(region)]

        new{R,I}(
            thermaldispatch, variabledispatch, storagedispatch,
            netload, unserved_energy, voll,
            import_interfaces, export_interfaces, region)

    end

end

cost(dispatch::RegionDispatch) =
    sum(cost(thermaltech) for thermaltech in dispatch.thermaltechs; init=0) +
    sum(cost(variabletech) for variabletech in dispatch.variabletechs; init=0) +
    sum(cost(storagetech) for storagetech in dispatch.storagetechs; init=0) +
    (isnan(dispatch.voll) ? 0 : sum(dispatch.unserved_energy) * (dispatch.voll * powerunits_MW))

name(dispatch::RegionDispatch) = name(dispatch.region)
demand(dispatch::RegionDispatch, t::Int) = demand(dispatch.region, t)

struct SystemDispatch{S<:System, R<:Region, I<:Interface}

    period::TimePeriod

    regions::Vector{RegionDispatch{R,I}}
    interfaces::Vector{InterfaceDispatch{I}}

    netimports::Matrix{JuMP_ExpressionRef}
    powerbalance::Matrix{JuMP_EqualToConstraintRef}

    system::S

    function SystemDispatch(
        m::JuMP.Model, system::S, period::TimePeriod, voll::Float64
    ) where { R<:Region, I<:Interface, S<:System{R,I} }

        n_timesteps = length(period)
        n_regions = length(system.regions)

        interfaces = [InterfaceDispatch(m, iface, period)
                   for iface in system.interfaces]

        regions = [RegionDispatch(m, region, interfaces, period, voll)
                   for region in system.regions]

        netimports = @expression(m, [r in 1:n_regions, t in 1:n_timesteps],
           sum(iface.flow[t] for iface in regions[r].import_interfaces) -
           sum(iface.flow[t] for iface in regions[r].export_interfaces)
        )

        powerbalance = @constraint(m, [r in 1:n_regions, t in 1:n_timesteps],
            regions[r].netload[t] == netimports[r,t])

        new{S,R,I}(period, regions, interfaces, netimports,
                   powerbalance, system)

    end

end

cost(dispatch::SystemDispatch) =
    sum(cost(region) for region in dispatch.regions; init=0)
