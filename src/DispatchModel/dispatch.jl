struct ThermalDispatch{G<:ThermalTechnology}

    dispatch::Vector{JuMP.VariableRef}
    units_committed::Vector{JuMP.VariableRef}

    units_committed_max::Vector{JuMP_LessThanConstraintRef}
    dispatch_max::Vector{JuMP_LessThanConstraintRef}
    dispatch_min::Vector{JuMP_LessThanConstraintRef}
    ramp_up_max::Vector{JuMP_LessThanConstraintRef}
    ramp_down_max::Vector{JuMP_LessThanConstraintRef}

    tech::G

    function ThermalDispatch(
        m::JuMP.Model, tech::G, period::TimePeriod
    ) where G <: ThermalTechnology

        T = length(period)
        ts = period.timesteps

        dispatch = @variable(m, [1:T], lower_bound = 0)
        fullname = join([name(tech), period.name], ",")
        varnames!(dispatch, "tech_dispatch[$(fullname)]", 1:T)

        units_committed = @variable(m, [1:T], integer=true, lower_bound = 0)
        varnames!(units_committed, "tech_units_committed[$(fullname)]", 1:T)

        units_committed_max = @constraint(m, [t in 1:T],
            units_committed[t] <= num_units(tech))

        dispatch_max = @constraint(m, [t in 1:T],
            dispatch[t] <= unit_size(tech) * units_committed[t])

        dispatch_min = @constraint(m, [t in 1:T],
            min_gen(tech) * units_committed[t] <= dispatch[t])

        ramp_up_max = @constraint(m, [t in 1:T],
            dispatch[t] - dispatch[prev_t(t, T)] <= max_unit_ramp(tech) * units_committed[t])

        ramp_down_max = @constraint(m, [t in 1:T],
            dispatch[prev_t(t, T)] - dispatch[t] <= max_unit_ramp(tech) * units_committed[t])

        return new{G}(dispatch, units_committed, units_committed_max, dispatch_max, dispatch_min, ramp_up_max, ramp_down_max, tech)

    end

end

cost(dispatch::ThermalDispatch) =
    sum(dispatch.dispatch) * cost_generation(dispatch.tech)

name(dispatch::ThermalDispatch) = name(dispatch.tech)

prev_t(t::Int, T::Int) = t == 1 ? T : t - 1


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
        m::JuMP.Model, stor::S, period::TimePeriod) where S <: StorageTechnology

        T = length(period)

        charge = @variable(m, [1:T], lower_bound = 0)
        fullname = join([name(stor), period.name], ",")
        varnames!(charge, "stor_charge[$(fullname)]", 1:T)

        discharge = @variable(m, [1:T], lower_bound = 0)
        fullname = join([name(stor), period.name], ",")
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
        m::JuMP.Model, tech::V, period::TimePeriod
    ) where V <: VariableTechnology

        T = length(period)
        ts = period.timesteps

        dispatch = @variable(m, [1:T], lower_bound = 0)
        fullname = join([name(tech), period.name], ",")
        varnames!(dispatch, "tech_dispatch[$(fullname)]", 1:T)

        dispatch_max = @constraint(m, [t in 1:T],
            dispatch[t] <= availablecapacity(tech, ts[t]))

        return new{V}(dispatch, dispatch_max, tech)

    end

end

cost(dispatch::VariableDispatch) =
    sum(dispatch.dispatch) * cost_generation(dispatch.tech)

name(dispatch::VariableDispatch) = name(dispatch.tech)


struct SystemDispatch{S<:System}

    period::TimePeriod

    thermaltechs::Vector{ThermalDispatch}
    variabletechs::Vector{VariableDispatch}
    storagetechs::Vector{StorageDispatch}

    unserved_energy::Union{Vector{JuMP.VariableRef},Nothing}
    voll::Float64

    powerbalance::Vector{JuMP_EqualToConstraintRef}

    system::S

    function SystemDispatch(
        m::JuMP.Model, system::S, period::TimePeriod, voll::Float64
    ) where { S <: System }

        n_timesteps = length(period)
        ts = period.timesteps

        thermaldispatch = [ThermalDispatch(m, tech, period)
                           for tech in thermaltechs(system)]

        variabledispatch = [VariableDispatch(m, tech, period)
                            for tech in variabletechs(system)]

        storagedispatch = [StorageDispatch(m, tech, period)
                           for tech in storagetechs(system)]

        unserved_energy = isnan(voll) ? nothing : @variable(m, [1:n_timesteps], lower_bound=0)

        powerbalance = @constraint(m, [t in 1:n_timesteps],
                demand(system, ts[t]) ==
                sum(gen.dispatch[t] for gen in thermaldispatch)
                + sum(gen.dispatch[t] for gen in variabledispatch)
                + sum(stor.dispatch[t] for stor in storagedispatch)
                + (isnan(voll) ? 0 : unserved_energy[t]))

        new{S}(period, thermaldispatch, variabledispatch, storagedispatch,
               unserved_energy, voll, powerbalance, system)

    end

end

name(dispatch::SystemDispatch) = name(dispatch.system)

demand(dispatch::SystemDispatch, t::Int) = demand(dispatch.system, t)

cost(dispatch::SystemDispatch) =
    sum(cost(thermaltech) for thermaltech in dispatch.thermaltechs; init=0) +
    sum(cost(variabletech) for variabletech in dispatch.variabletechs; init=0) +
    sum(cost(storagetech) for storagetech in dispatch.storagetechs; init=0) +
    (isnan(dispatch.voll) ? 0 : sum(dispatch.unserved_energy) * (dispatch.voll * powerunits_MW))
