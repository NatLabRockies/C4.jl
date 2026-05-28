import PRASCore.Results: ResultSpec, ResultAccumulator, Result

"""
A quick-and-dirty calculation for incremental EUE improvement from different
storage parameters (charge capacity, discharge capacity, energy capacity).
We make a number of assumptions that work in the single-region case in C4, but
not in general for PRAS. In particular:

 - We ignore storage outages
 - We ignore interactions with transmission congestion
 - We assume carryover efficiency = 1.0
 - We assume roundtrip efficiency = charge_efficiency^2
"""
struct MarginalEUE <: ResultSpec end

@enum EUEStorageBinding begin
    NonBinding
    ChargeBinding
    ReservoirBinding
    DischargeBinding
end

struct MarginalEUEAccumulator <: ResultAccumulator{MarginalEUE}

    nsamples::Int 

    storage_state::Vector{EUEStorageBinding}
    storage_chargelimit_reached::Vector{Int}

    storage_charge::Vector{Float64}
    storage_discharge::Vector{Float64}
    storage_energy::Vector{Float64}

end

function PRASCore.Results.accumulator(
    sys::SystemModel, nsamples::Int, ::MarginalEUE
)

    n_storages = length(sys.storages)

    return MarginalEUEAccumulator(
        nsamples, fill(NonBinding, n_storages), zeros(Int, n_storages),
        zeros(n_storages), zeros(n_storages), zeros(n_storages))

end

function PRASCore.Results.merge!(
    x::MarginalEUEAccumulator, y::MarginalEUEAccumulator
)

    x.storage_charge .+= y.storage_charge
    x.storage_discharge .+= y.storage_discharge
    x.storage_energy .+= y.storage_energy

    return

end

PRASCore.Results.accumulatortype(::MarginalEUE) =
    MarginalEUEAccumulator

struct StorMarginalEUE
    charge::Float64
    discharge::Float64
    energy::Float64
end

struct MarginalEUEResult{N,L,T} <: Result{N,L,T}

    region_stor_idxs::Vector{UnitRange{Int}} 
    storages::Vector{StorMarginalEUE}

end

function PRASCore.Results.finalize(
    acc::MarginalEUEAccumulator,
    system::SystemModel{N,L,T},
) where {N,L,T}

    return MarginalEUEResult{N,L,T}(
        system.region_stor_idxs,
        StorMarginalEUE.(
            .- acc.storage_charge ./ acc.nsamples,
            .- acc.storage_discharge ./ acc.nsamples,
            .- acc.storage_energy ./ acc.nsamples
        )
    )

end

function PRASCore.Simulations.record!(
    acc::MarginalEUEAccumulator,
    system::SystemModel,
    state::PRASCore.Simulations.SystemState,
    problem::PRASCore.Simulations.DispatchProblem,
    sampleid::Int, t::Int
)

    for (s, sc_idx) in enumerate(problem.storage_charge_edges)

        charge_edge = problem.fp.edges[sc_idx]

        maxenergy = system.storages.energy_capacity[s,t]
        maxcharge = system.storages.charge_capacity[s,t]
        storageenergy = state.stors_energy[s]

        if charge_edge.flow == maxcharge
            acc.storage_state[s] = ChargeBinding
            acc.storage_chargelimit_reached[s] += 1
        elseif storageenergy == maxenergy
            acc.storage_state[s] = ReservoirBinding
            acc.storage_chargelimit_reached[s] = 0
        end

    end

    # increase marginal EUE reduction potentials if shortfall anywhere
    # note this ignores deliverability, not generally correct for
    # multi-region systems

    has_shortfall = false

    for r in problem.region_unserved_edges

        problem.fp.edges[r].flow == 0 && continue

        has_shortfall = true
        break

    end

    !has_shortfall && return

    for (s, sd_idx) in enumerate(problem.storage_discharge_edges)

        discharge_edge = problem.fp.edges[sd_idx]
        maxdischarge = system.storages.discharge_capacity[s,t]

        if discharge_edge.flow == maxdischarge
            acc.storage_discharge[s] += 1
        elseif acc.storage_state[s] == ChargeBinding
            count_limited = acc.storage_chargelimit_reached[s]
            acc.storage_charge[s] += count_limited * system.storages.charge_efficiency[s,t]^2
            acc.storage_state[s] = NonBinding
            acc.storage_chargelimit_reached[s] = 0
        elseif acc.storage_state[s] == ReservoirBinding
            acc.storage_energy[s] += 1
            acc.storage_state[s] = NonBinding
        end

    end

    return

end

function PRASCore.Simulations.reset!(
    acc::MarginalEUEAccumulator, sampleid::Int)

    acc.storage_state .= NonBinding
    return

end
