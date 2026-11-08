mutable struct StorageDispatchRecurrence

    soc_last::JuMP.VariableRef
    soc_last_definition::JuMP_EqualToConstraintRef

    emin_first::JuMP_LessThanConstraintRef
    emax_first::JuMP_LessThanConstraintRef
    emin_last::JuMP_LessThanConstraintRef
    emax_last::JuMP_LessThanConstraintRef

    function StorageDispatchRecurrence(
        m::JuMP.Model, storage::DispatchableStorageTech)

        soc_last = @variable(m, base_name="stor_ending_soc[" * name(storage) * "]")

        # Other fields will be populated during second pass (setup_recurrence!)
        new(soc_last)

    end

end

function setup_recurrence!(
    m::JuMP.Model,
    recurrence::StorageDispatchRecurrence,
    prev_recurrence::StorageDispatchRecurrence,
    storage::DispatchableStorageTech, dispatch::StorageDispatch,
    repetitions::Int, invyear::Int)

    energy = maxenergy(storage, invyear)

    soc0_first = prev_recurrence.soc_last
    soc0_last = soc0_first + (repetitions - 1) * dispatch.e_net

    recurrence.soc_last_definition = @constraint(m,
        recurrence.soc_last == soc0_first + repetitions * dispatch.e_net,
        base_name="stor_ending_soc_definition[" * name(storage) * "]")

    recurrence.emin_first = @constraint(m, 0 <= soc0_first + dispatch.e_low)
    recurrence.emax_first = @constraint(m, soc0_first + dispatch.e_high <= energy)
    recurrence.emin_last = @constraint(m, 0 <= soc0_last + dispatch.e_low)
    recurrence.emax_last = @constraint(m, soc0_last + dispatch.e_high <= energy)

    return

end

struct DispatchRecurrence{S <: DispatchableSystem}

    dispatch::SystemDispatch{S} # Note this is just a reference, data is owned elsewhere
    repetitions::Int

    storagetechs::Vector{StorageDispatchRecurrence}

    function DispatchRecurrence(
        m::JuMP.Model, system::S, dispatch::D, repetitions::Int
    ) where {S <: DispatchableSystem, D <: SystemDispatch{S}}

        stors = [StorageDispatchRecurrence(m, stor)
                 for stor in storagetechs(system)]

        new{S}(dispatch, repetitions, stors)

    end

end

function setup_recurrence!(
    m::JuMP.Model, recurrence::R, prev_recurrence::R, system::S, invyear::Int
) where { S <: DispatchableSystem, R <: DispatchRecurrence{S} }

    for (s, stor) in enumerate(storagetechs(system))

        setup_recurrence!(m,
            recurrence.storagetechs[s],
            prev_recurrence.storagetechs[s],
            stor,
            recurrence.dispatch.storagetechs[s],
            recurrence.repetitions, invyear)

    end
   
end

cost(recurrence::DispatchRecurrence) =
    cost(recurrence.dispatch) * recurrence.repetitions

co2(recurrence::DispatchRecurrence) =
    co2(recurrence.dispatch) * recurrence.repetitions

struct DispatchSequence{S <: DispatchableSystem}

    time::DispatchProxyMappings

    dispatches::Vector{SystemDispatch{S}}
    recurrences::Vector{Vector{DispatchRecurrence{S}}}

    co2_offsets::Union{JuMP.VariableRef,Nothing} # tonnes CO2
    co2_constraint::Union{JuMP_LessThanConstraintRef,Nothing} # tonnes CO2
    co2_offset_price::Float64 # $/tonne CO2

    function DispatchSequence(
        m::JuMP.Model, system::S, invyear::Int, time::DispatchProxyMappings;
        voll::Float64=NaN, co2_max::Float64=NaN, co2_offset_price::Float64=999.,
        unit_commitment::Bool=true
    ) where {S <: DispatchableSystem}

        dispatches = [SystemDispatch(m, system, invyear, day, voll,
                                     unit_commitment=unit_commitment)
                      for day in time.days]

        recurrences = [
            sequence_recurrences(m, system, dispatches, invyear, time, dy)
            for dy in eachindex(time.mappings)]

        if isnan(co2_max)
            co2_offsets = co2_constraint = nothing
        else
            co2_offsets = @variable(m, lower_bound=0)
            co2_total = annualization_factor(time) *
                        sum(sum(co2(recc) for recc in dy_reccs; init=0)
                            for dy_reccs in recurrences)
            co2_constraint = @constraint(m, co2_total - co2_offsets <= co2_max)
        end

        new{S}(time, dispatches, recurrences,
               co2_offsets, co2_constraint, co2_offset_price)

    end

end

co2(sequence::DispatchSequence) =
    annualization_factor(sequence.time) *
    sum(sum(co2(recurrence) for recurrence in dy_recurrences; init=0)
        for dy_recurrences in sequence.recurrences; init=0)

co2_offset_cost(sequence::DispatchSequence) = if isnothing(sequence.co2_offsets)
    0.
else
    annualization_factor(sequence.time) * sequence.co2_offsets * sequence.co2_offset_price
end

generation_cost(sequence::DispatchSequence) =
    annualization_factor(sequence.time) *
    sum(sum(cost(recurrence) for recurrence in dy_recurrences; init=0)
    for dy_recurrences in sequence.recurrences)

cost(sequence::DispatchSequence) =
    co2_offset_cost(sequence) + generation_cost(sequence)

function sequence_recurrences(
    m::JuMP.Model, system::S, dispatches::Vector{SystemDispatch{S}},
    invyear::Int, time::DispatchProxyMappings, mapping_idx::Int
) where S <: DispatchableSystem

    sequence = deduplicate(time.mappings[mapping_idx].mapping)
    recurrences = Vector{DispatchRecurrence{S}}(undef, length(sequence))

    # First pass - initialize recurrences

    recurrences = [
        DispatchRecurrence(m, system, dispatches[p], repetitions)
        for (p, repetitions) in sequence]

    # Second pass - wire up constraints

    prev_recurrence = last(recurrences)

    for recurrence in recurrences
        setup_recurrence!(m, recurrence, prev_recurrence, system, invyear)
        prev_recurrence = recurrence
    end

    return recurrences

end

function deduplicate(xs::Vector{Int})

    result = Pair{Int,Int}[]

    iszero(length(xs)) && return result

    x_prev = first(xs)
    repetitions = 1

    for x in xs[2:end]

        if x == x_prev
            repetitions += 1
            continue
        end

        push!(result, x_prev=>repetitions)

        x_prev = x
        repetitions = 1

    end

    push!(result, x_prev=>repetitions)

    return result

end
