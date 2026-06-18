struct ThermalDispatch{G<:ThermalTechnology}

    dispatch::Vector{JuMP.VariableRef}
    units_committed::Vector{JuMP.VariableRef}
    units_startup::Vector{JuMP.VariableRef}
    units_shutdown::Vector{JuMP.VariableRef}

    units_committed_max::Vector{JuMP_LessThanConstraintRef}
    commitment_state::Vector{JuMP_EqualToConstraintRef}
    min_up_time::Vector{JuMP_LessThanConstraintRef}
    min_down_time::Vector{JuMP_LessThanConstraintRef}
    dispatch_max::Vector{JuMP_LessThanConstraintRef}
    dispatch_min::Vector{JuMP_LessThanConstraintRef}
    ramp_up_max::Vector{JuMP_LessThanConstraintRef}
    ramp_down_max::Vector{JuMP_LessThanConstraintRef}

    tech::G

    function ThermalDispatch(
        m::JuMP.Model, tech::G, period::TimePeriod;
        unit_commitment::Bool=true
    ) where G <: ThermalTechnology

        T = length(period)
        ts = period.timesteps

        dispatch = @variable(m, [1:T], lower_bound = 0)
        fullname = join([name(tech), period.name], ",")
        varnames!(dispatch, "tech_dispatch[$(fullname)]", 1:T)

        if unit_commitment

            units_committed = @variable(m, [1:T], integer=true, lower_bound = 0)
            varnames!(units_committed, "tech_units_committed[$(fullname)]", 1:T)

            units_startup = @variable(m, [1:T], binary=true, lower_bound = 0)
            varnames!(units_startup, "tech_units_startup[$(fullname)]", 1:T)

            units_shutdown = @variable(m, [1:T], binary=true, lower_bound = 0)
            varnames!(units_shutdown, "tech_units_shutdown[$(fullname)]", 1:T)

            units_committed_max = @constraint(m, [t in 1:T],
                units_committed[t] <= num_units(tech))

            commitment_state = @constraint(m, [t in 1:T],
                units_committed[t] == units_committed[prev_t(t, T)] + units_startup[t] - units_shutdown[t])

            min_up_time = @constraint(m, [t in 1:T],
                sum(units_startup[tt] for tt in last_n(t, min_uptime(tech), T)) <= units_committed[t])

            min_down_time = @constraint(m, [t in 1:T],
                sum(units_shutdown[tt] for tt in last_n(t, min_downtime(tech), T)) <= num_units(tech) - units_committed[t])

            dispatch_max = @constraint(m, [t in 1:T],
                dispatch[t] <= unit_size(tech) * units_committed[t])

            dispatch_min = @constraint(m, [t in 1:T],
                min_gen(tech) * units_committed[t] <= dispatch[t])

            ramp_up_max = @constraint(m, [t in 1:T],
                dispatch[t] - dispatch[prev_t(t, T)] <= max_unit_ramp(tech) * (units_committed[t] - units_startup[t]) - min_gen(tech) * units_shutdown[t] + max(min_gen(tech), max_unit_ramp(tech)) * units_startup[t]
                )

            ramp_down_max = @constraint(m, [t in 1:T],
                dispatch[prev_t(t, T)] - dispatch[t] <= max_unit_ramp(tech) * (units_committed[t] - units_startup[t]) - min_gen(tech) * units_startup[t] + max(min_gen(tech), max_unit_ramp(tech)) * units_shutdown[t]
                )

        else

            # No UC: dispatch-only, bounded by nameplatecapacity.
            # No commitment vars, no startup/shutdown, no ramp limits.
            units_committed     = JuMP.VariableRef[]
            units_startup       = JuMP.VariableRef[]
            units_shutdown      = JuMP.VariableRef[]

            units_committed_max = JuMP_LessThanConstraintRef[]
            commitment_state    = JuMP_EqualToConstraintRef[]
            min_up_time         = JuMP_LessThanConstraintRef[]
            min_down_time       = JuMP_LessThanConstraintRef[]

            dispatch_max = @constraint(m, [t in 1:T],
                dispatch[t] <= nameplatecapacity(tech))

            dispatch_min  = JuMP_LessThanConstraintRef[]

            ramp_up_max = @constraint(m, [t in 1:T],
                dispatch[t] - dispatch[prev_t(t, T)] <= max_unit_ramp(tech) * num_units(tech))

            ramp_down_max = @constraint(m, [t in 1:T],
                dispatch[prev_t(t, T)] - dispatch[t] <= max_unit_ramp(tech) * num_units(tech))

        end

        return new{G}(dispatch, units_committed, units_startup, units_shutdown, units_committed_max, commitment_state, dispatch_max, min_up_time, min_down_time, dispatch_min, ramp_up_max, ramp_down_max, tech)

    end

end

cost(dispatch::ThermalDispatch) =
    (isempty(dispatch.units_startup) ? 0 : cost_startup(dispatch.tech) * sum(dispatch.units_startup)) +
    cost_generation(dispatch.tech) * sum(dispatch.dispatch)

co2(dispatch::ThermalDispatch) =
    (isempty(dispatch.units_startup) ? 0 : co2_startup(dispatch.tech) * sum(dispatch.units_startup)) +
    co2_generation(dispatch.tech) * sum(dispatch.dispatch)

name(dispatch::ThermalDispatch) = name(dispatch.tech)

prev_t(t::Int, T::Int) = t == 1 ? T : t - 1

function last_n(t::Int, n::Int, T::Int)
    inds = Vector{Int}(undef, n)
    for i in n:-1:1
        inds[i] = t
        t = prev_t(t, T)
    end
    return inds
end


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
        m::JuMP.Model, system::S, period::TimePeriod, voll::Float64;
        unit_commitment::Bool=true
    ) where { S <: System }

        n_timesteps = length(period)
        ts = period.timesteps

        thermaldispatch = [ThermalDispatch(m, tech, period, unit_commitment=unit_commitment)
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

co2(dispatch::SystemDispatch) =
    sum(co2(thermaltech) for thermaltech in dispatch.thermaltechs; init=0)
