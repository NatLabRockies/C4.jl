struct StorageDispatchRecurrence

    emin_first::JuMP_LessThanConstraintRef
    emax_first::JuMP_LessThanConstraintRef
    emin_last::JuMP_LessThanConstraintRef
    emax_last::JuMP_LessThanConstraintRef

    soc_last::JuMP_ExpressionRef

    function StorageDispatchRecurrence(
        m::JuMP.Model,
        prev_recurrence::Union{StorageDispatchRecurrence,Nothing},
        storage::DispatchableStorageTech, dispatch::StorageDispatch,
        repetitions::Int, invyear::Int)

        energy = maxenergy(storage, invyear) # TODO: Need to get invyear down to here!

        soc0_first = isnothing(prev_recurrence) ? 0 : prev_recurrence.soc_last
        soc0_last = soc0_first + (repetitions - 1) * dispatch.e_net

        emin_first = @constraint(m, 0 <= soc0_first + dispatch.e_low)
        emax_first = @constraint(m, soc0_first + dispatch.e_high <= energy)
        emin_last = @constraint(m, 0 <= soc0_last + dispatch.e_low)
        emax_last = @constraint(m, soc0_last + dispatch.e_high <= energy)

        soc_last = soc0_first + repetitions * dispatch.e_net

        new(emin_first, emax_first, emin_last, emax_last, soc_last)

    end

end

struct DispatchRecurrence{S <: DispatchableSystem}

    dispatch::SystemDispatch{S} # Note this is just a reference, data is owned elsewhere
    repetitions::Int

    storagetechs::Vector{StorageDispatchRecurrence}

    function DispatchRecurrence(
        m::JuMP.Model, prev_recurrence::Union{DispatchRecurrence{S},Nothing},
        system::S, dispatch::SystemDispatch{S}, repetitions::Int, invyear::Int
    ) where S <: DispatchableSystem

        prev_recurrence_stors = isnothing(prev_recurrence) ?
            StorageDispatchRecurrence[] : prev_recurrence.storagetechs

        stors = [
            StorageDispatchRecurrence(
                m, prev_storrecurrence, stor, stordispatch, repetitions, invyear)
            for (prev_storrecurrence, stor, stordispatch)
            in zip_longest(prev_recurrence_stors, storagetechs(system), dispatch.storagetechs)
        ]

        new{S}(dispatch, repetitions, stors)

    end

end

cost(recurrence::DispatchRecurrence) =
    cost(recurrence.dispatch) * recurrence.repetitions

co2(recurrence::DispatchRecurrence) =
    co2(recurrence.dispatch) * recurrence.repetitions

struct DispatchSequence{S <: DispatchableSystem}

    time::DispatchProxyMapping

    dispatches::Vector{SystemDispatch{S}}
    recurrences::Vector{DispatchRecurrence{S}}

    co2_offsets::Union{JuMP.VariableRef,Nothing} # tonnes CO2
    co2_constraint::Union{JuMP_LessThanConstraintRef,Nothing} # tonnes CO2
    co2_offset_price::Float64 # $/tonne CO2

    function DispatchSequence(
        m::JuMP.Model, system::S, invyear::Int, time::DispatchProxyMapping;
        voll::Float64=NaN, co2_max::Float64=NaN, co2_offset_price::Float64=999.,
        unit_commitment::Bool=true
    ) where {S <: DispatchableSystem}

        dispatches = [SystemDispatch(m, system, invyear, day, voll,
                                     unit_commitment=unit_commitment)
                      for day in time.days]

        recurrences = sequence_recurrences(m, system, dispatches, invyear, time)

        if isnan(co2_max)
            co2_offsets = co2_constraint = nothing
        else
            co2_offsets = @variable(m, lower_bound=0)
            co2_total = sum(co2(recc) for recc in recurrences; init=0)
            co2_constraint = @constraint(m, co2_total - co2_offsets <= co2_max)
        end

        new{S}(time, dispatches, recurrences,
               co2_offsets, co2_constraint, co2_offset_price)

    end

end

co2(sequence::DispatchSequence) =
    sum(co2(recurrence) for recurrence in sequence.recurrences; init=0)

co2_offset_cost(sequence::DispatchSequence) =
    (isnothing(sequence.co2_offsets) ? 0. :
        sequence.co2_offsets * sequence.co2_offset_price)

cost(sequence::DispatchSequence) =
    sum(cost(recurrence) for recurrence in sequence.recurrences; init=0) +
    co2_offset_cost(sequence)

function sequence_recurrences(
    m::JuMP.Model, system::S, dispatches::Vector{SystemDispatch{S}},
    invyear::Int, time::DispatchProxyMapping
) where S <: DispatchableSystem

    sequence = deduplicate(time.mapping)
    recurrences = Vector{DispatchRecurrence{S}}(undef, length(sequence))

    prev_recurrence = nothing

    for (i, (p, repetitions)) in enumerate(sequence)

        recurrence = DispatchRecurrence(m, prev_recurrence, system,
                                        dispatches[p], repetitions, invyear)

        recurrences[i]  = recurrence
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
