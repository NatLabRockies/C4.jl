struct StorageDispatchRecurrence

    emin_first::JuMP_LessThanConstraintRef
    emax_first::JuMP_LessThanConstraintRef
    emin_last::JuMP_LessThanConstraintRef
    emax_last::JuMP_LessThanConstraintRef

    soc_last::JuMP_ExpressionRef

    function StorageDispatchRecurrence(
        m::JuMP.Model,
        prev_recurrence::Union{StorageDispatchRecurrence,Nothing},
        storage::StorageTechnology, dispatch::StorageDispatch,
        repetitions::Int)

        energy = maxenergy(storage)

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

struct RegionDispatchRecurrence

    storagetechs::Vector{StorageDispatchRecurrence}

    function RegionDispatchRecurrence(
        m::JuMP.Model,
        prev_recurrence::Union{RegionDispatchRecurrence,Nothing},
        region::Region, dispatch::RegionDispatch, repetitions::Int
    )

        prev_recurrence_stors = isnothing(prev_recurrence) ?
            StorageDispatchRecurrence[] : prev_recurrence.storagetechs

        stors = [
            StorageDispatchRecurrence(
                m, prev_storrecurrence, stor, stordispatch, repetitions)
            for (prev_storrecurrence, stor, stordispatch)
            in zip_longest(prev_recurrence_stors, storagetechs(region), dispatch.storagetechs)
        ]

        new(stors)

    end

end

struct DispatchRecurrence{D <: SystemDispatch}

    dispatch::D # Note this is just a reference, data is owned elsewhere
    repetitions::Int

    regions::Vector{RegionDispatchRecurrence}

    function DispatchRecurrence(
        m::JuMP.Model, prev_recurrence::Union{DispatchRecurrence{D},Nothing},
        system::System, dispatch::D, repetitions::Int
    ) where D <: SystemDispatch

        prev_recurrence_regions = isnothing(prev_recurrence) ?
            RegionDispatchRecurrence[] : prev_recurrence.regions

        regions = [
            RegionDispatchRecurrence(
                m, prev_regionrecurrence, region, regiondispatch, repetitions)
            for (prev_regionrecurrence, region, regiondispatch)
            in zip_longest(prev_recurrence_regions, system.regions, dispatch.regions)]

        new{D}(dispatch, repetitions, regions)

    end

end

cost(recurrence::DispatchRecurrence) =
    cost(recurrence.dispatch) * recurrence.repetitions

struct DispatchSequence{D <: SystemDispatch}

    time::TimeProxyAssignment

    dispatches::Vector{D}
    recurrences::Vector{DispatchRecurrence{D}}

    function DispatchSequence(
        m::JuMP.Model, system::S, time::TimeProxyAssignment, voll::Float64=NaN
    ) where {R, I, S <: System{R,I}}

        dispatches = [SystemDispatch(m, system, period, voll) for period in time.periods]
        recurrences = sequence_recurrences(m, system, dispatches, time)
        new{SystemDispatch{S,R,I}}(time, dispatches, recurrences)

    end

end

cost(sequence::DispatchSequence) =
    sum(cost(recurrence) for recurrence in sequence.recurrences; init=0)

function sequence_recurrences(
    m::JuMP.Model, system::System, dispatches::Vector{D}, time::TimeProxyAssignment
) where D <: SystemDispatch

    sequence = deduplicate(time.days)
    recurrences = Vector{DispatchRecurrence{D}}(undef, length(sequence))

    prev_recurrence = nothing

    for (i, (p, repetitions)) in enumerate(sequence)

        recurrence = DispatchRecurrence(m, prev_recurrence, system, dispatches[p], repetitions)

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
