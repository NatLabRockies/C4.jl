# TODO: Differentiate reliability vs economic dispatch in variable names
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

"""
RegionDispatch is an abstract type for holding optimization problem components
for dispatching a Region. RegionDispatch instance constructors should take the
following arguments:
```
RegionDispatch(::JuMP.Model, ::Region, ::Vector{InterfaceDispatch}, ::TimePeriod)
```
"""
abstract type RegionDispatch{R<:Region} end

name(dispatch::RegionDispatch) = name(dispatch.region)
demand(dispatch::RegionDispatch, t::Int) = demand(dispatch.region, t)

"""
SystemDispatch contains optimization problem components for
dispatching a System. SystemDispatch constructors should take the
following arguments:
```
SystemDispatch(::JuMP.Model, ::System, ::TimePeriod)
```
"""
abstract type SystemDispatch{S<:System} end
