import Base.Threads: nthreads, @spawn

import Random: rand, seed!, AbstractRNG
import Random123: Philox4x

# For now, focus on exactness, not speed: Replace Float64 with Rational{Int}
# A more specific / clever approach is probably possible, revisit this later

# A small enhancement could be to represent non-negative values as Rational{UInt} -
# this increases resolution and range, but does it help at all?

struct StorageParams
    charge_eff::Rational{Int}
    discharge_eff::Rational{Int}
    power_capacity::Rational{Int}
    energy_capacity::Rational{Int}
end

struct AdequacyParams

    n_timesteps::Int
    n_generators::Int
    n_storages::Int

    demand::Vector{Rational{Int}} # n_timesteps

    # Note this index ordering is deliberately inconsistent,
    # for better contiguous memory access
    generators_capacity::Matrix{Rational{Int}} # n_generators x n_timesteps
    generators_lambda::Matrix{Float64} # n_timesteps x n_generators
    generators_mu::Matrix{Float64} # n_timesteps x n_generators

    # Note: Provided storages MUST be pre-sorted by round-trip efficiency
    storages::Vector{StorageParams} # n_storages

    function AdequacyParams(
        demand::Vector{Rational{Int}},
        generators_capacity::Matrix{Rational{Int}},
        generators_lambda::Matrix{Float64},
        generators_mu::Matrix{Float64},
        storages::Vector{StorageParams})

        n_timesteps = length(demand)
        n_generators = size(generators_capacity, 1)
        n_storages = length(storages)

        size(generators_capacity, 2) == n_timesteps || error("Inconsistent number of timesteps")

        size(generators_lambda, 1) == n_timesteps || error("Inconsistent number of timesteps")
        size(generators_lambda, 2) == n_generators || error("Inconsistent number of generators")

        size(generators_mu, 1) == n_timesteps || error("Inconsistent number of timesteps")
        size(generators_mu, 2) == n_generators || error("Inconsistent number of generators")

        issorted([stor.charge_eff * stor.discharge_eff for stor in storages], rev=true) ||
            error("Storages must be provided in order of decreasing round-trip efficiency")

        new(n_timesteps, n_generators, n_storages, demand,
            generators_capacity, generators_lambda, generators_mu, storages)

    end

end

struct DispatchState

    n_timesteps::Int
    n_storages::Int

    imbalance_prestorage::Vector{Rational{Int}} # n_timesteps - hacky but fine for now
    imbalance::Vector{Rational{Int}} # n_timesteps
    
    generator_nexttransition::Vector{Int32} # n_generators

    storage_soc::Vector{Rational{Int}} # n_storages
    storage_dispatch::Matrix{Rational{Int}}  # n_timesteps x n_storages

    # For incremental addition dual, only ever 0, 1, or RTE of a storage, could be UInt8?
    dEUE_generator::Vector{Rational{Int}} # n_timesteps

    # For incremental addition dual, only ever 0 or discharge_eff, could be bool?
    dEUE_storage_energy::Matrix{Rational{Int}} # n_timesteps x n_storages
    
    dEUE_storage_charge_limit::Matrix{Rational{Int}} # n_timesteps x n_storages
    dEUE_storage_discharge_limit::Matrix{Rational{Int}} # n_timesteps x n_storages
    dEUE_storage_energy_limit::Matrix{Rational{Int}} # n_timesteps x n_storages

    function DispatchState(prob::AdequacyParams)
        
        new(
        
            prob.n_timesteps, prob.n_storages,
            
            Vector{Rational{Int}}(undef, prob.n_timesteps),
            Vector{Rational{Int}}(undef, prob.n_timesteps),
            
            Vector{Int32}(undef, prob.n_generators),
            
            Vector{Rational{Int}}(undef, prob.n_storages),
            Matrix{Rational{Int}}(undef, prob.n_timesteps, prob.n_storages),
            
            Vector{Rational{Int}}(undef, prob.n_timesteps),
            Matrix{Rational{Int}}(undef, prob.n_timesteps, prob.n_storages),
            
            Matrix{Rational{Int}}(undef, prob.n_timesteps, prob.n_storages),
            Matrix{Rational{Int}}(undef, prob.n_timesteps, prob.n_storages),
            Matrix{Rational{Int}}(undef, prob.n_timesteps, prob.n_storages)

        )
        
    end

end

mutable struct ResultAccumulator
    
    n_timesteps::Int
    n_samples::Int
    
    lolps::Vector{Float64} # n_timesteps
    eues::Vector{Float64} # n_timesteps
    
    dEUE_generator::Vector{Float64} # n_timesteps
    dEUE_storage_power::Matrix{Float64} # n_timesteps x n_storages
    dEUE_storage_energy::Matrix{Float64} # n_timesteps x n_storages

    ResultAccumulator(prob::AdequacyParams) =
        new(prob.n_timesteps, 0,
            zeros(prob.n_timesteps), zeros(prob.n_timesteps),
            zeros(prob.n_timesteps),
            zeros(prob.n_timesteps, prob.n_storages),
            zeros(prob.n_timesteps, prob.n_storages)
        )

end

function merge!(acc1::ResultAccumulator, acc2::ResultAccumulator)

    acc1.n_samples += acc2.n_samples

    acc1.lolps .+= acc2.lolps
    acc1.eues .+= acc2.eues

    acc1.dEUE_generator .+= acc2.dEUE_generator
    acc1.dEUE_storage_power .+= acc2.dEUE_storage_power
    acc1.dEUE_storage_energy .+= acc2.dEUE_storage_energy

    return

end

function solve_single!(
    state::DispatchState, results::ResultAccumulator,
    prob::AdequacyParams, sample_idx::Int)
    
    initialize!(state, prob, sample_idx)
    results.n_samples += 1
    # println(state.imbalance_prestorage)

    for t in 1:prob.n_timesteps

        if state.imbalance[t] > 0
            shift_energy_forward!(state, prob, t) # Majority of simulation time spent here now?
        else
            drawdown_soc!(state, prob, t)
            record_primals!(results, state, t)
        end

    end

    for t in prob.n_timesteps:-1:1

        if state.imbalance[t] < 0
            calc_duals_discharge_shortfall!(state, prob, t)
        elseif state.imbalance_prestorage[t] < 0
            calc_duals_discharge_noshortfall!(state, prob, t)
        else
            calc_duals_charge!(state, prob, t)
        end

        backtrack_soc!(state, prob, t)
        record_duals!(results, state, t)

    end

    check_strong_duality(prob, state)

    return

end

function check_strong_duality(prob::AdequacyParams, state::DispatchState)
    
    primal_objval = sum(-sp for sp in state.imbalance if sp < 0; init=0//1)

    dEUE_charge_power = vec(sum(state.dEUE_storage_charge_limit, dims=1))
    dEUE_discharge_power = vec(sum(state.dEUE_storage_discharge_limit, dims=1))
    dEUE_energy = vec(sum(state.dEUE_storage_energy_limit, dims=1))
        
    dual_objval = -sum(
        dEUE_chg_p * stor.power_capacity +
        dEUE_dchg_p * stor.power_capacity/stor.discharge_eff +
        dEUE_e * stor.energy_capacity
        for (dEUE_chg_p, dEUE_dchg_p, dEUE_e, stor)
        in zip(dEUE_charge_power, dEUE_discharge_power, dEUE_energy, prob.storages); init=0//1) -
        sum(state.imbalance_prestorage .* state.dEUE_generator)

    if primal_objval != dual_objval
        error("Strong duality violation - primal = $primal_objval, dual = $dual_objval")
    end

end

function initialize!(state::DispatchState, prob::AdequacyParams, sample_idx::Int)
    
    sample_surplus!(state, prob, sample_idx)
    
    fill!(state.storage_soc, 0) # Could take this from user
    fill!(state.storage_dispatch, 0)
    
    fill!(state.dEUE_generator, 0)
    fill!(state.dEUE_storage_energy, 0)
    
    fill!(state.dEUE_storage_charge_limit, 0)
    fill!(state.dEUE_storage_discharge_limit, 0)
    fill!(state.dEUE_storage_energy_limit, 0)

    return

end

function sample_surplus!(state::DispatchState, prob::AdequacyParams, sample_idx::Int)

    rng = Philox4x((sample_idx, sample_idx), 10)

    # TODO: Update counter predictably based on g (generator name hash?) and t.
    #       For now we just use automatic incrementing

    # Initialize transitions away from starting states
    for g in 1:prob.n_generators

        lambda = prob.generators_lambda[1, g]
        mu = prob.generators_mu[1, g]

        if rand(rng) < mu / (lambda + mu) # unit starts available
            unavailable_probs = view(prob.generators_lambda, :, g)
            state.generator_nexttransition[g] =
                randtransitiontime(rng, unavailable_probs, 1, prob.n_timesteps)
        else # unit starts unavailable
            available_probs = view(prob.generators_mu, :, g)
            state.generator_nexttransition[g] =
                -randtransitiontime(rng, available_probs, 1, prob.n_timesteps)
        end

    end

    for t in 1:prob.n_timesteps

        surplus = -prob.demand[t]

        for g in 1:prob.n_generators

            if state.generator_nexttransition[g] > 0 # previously available

                transitioning = t == state.generator_nexttransition[g]

                if transitioning

                    available_probs = view(prob.generators_mu, :, g)
                    state.generator_nexttransition[g] =
                        -randtransitiontime(rng, available_probs, t, prob.n_timesteps)

                else

                    surplus += prob.generators_capacity[g,t]

                end

            else # previously unavailable

                transitioning = t == -state.generator_nexttransition[g]

                if transitioning

                    unavailable_probs = view(prob.generators_lambda, :, g)
                    # 1/3 of init time spent here - why 3x more than above randtransitiontime call?
                    # Shouldn't they happen equally frequently?
                     state.generator_nexttransition[g] =
                        randtransitiontime(rng, unavailable_probs, t, prob.n_timesteps)
                    surplus += prob.generators_capacity[g,t]

                end

            end

        end

        state.imbalance[t] = surplus

    end

    state.imbalance_prestorage .= state.imbalance

    return

end

# Adapted from PRAS
function randtransitiontime(
    rng::AbstractRNG, p::AbstractVector{Float64}, t_now::Int, t_last::Int
)

    cdf = 0.
    p_noprevtransition = 1.

    x = rand(rng)
    t = t_now + 1

    while t <= t_last
        p_t = p[t]
        cdf += p_noprevtransition * p_t
        x < cdf && return t
        p_noprevtransition *= (1. - p_t)
        t += 1
    end

    return t_last + 1

end

function shift_energy_forward!(
    state::DispatchState, prob::AdequacyParams, t0::Int)

    surplus_t0 = state.imbalance[t0]
    
    for (s, stor) in enumerate(prob.storages)

        max_chargeable_t0 = min(
            surplus_t0, stor.power_capacity,
            (stor.energy_capacity - state.storage_soc[s]) / stor.charge_eff)

        charge_t0 = 0//1

        for t in (t0+1):prob.n_timesteps

            shortfall_t = -state.imbalance[t] 
            shortfall_t < 0 && continue

            discharge_t = min(
                shortfall_t,
                stor.power_capacity - state.storage_dispatch[t, s],
                (max_chargeable_t0 - charge_t0) * stor.charge_eff * stor.discharge_eff)

            state.storage_dispatch[t, s] += discharge_t
            state.imbalance[t] += discharge_t

            charge_t0_t = discharge_t / stor.charge_eff / stor.discharge_eff

            charge_t0 += charge_t0_t
            surplus_t0 -= charge_t0_t

            (charge_t0 < max_chargeable_t0) || break

        end
        
        state.storage_dispatch[t0, s] = -charge_t0
        state.storage_soc[s] += charge_t0 * stor.charge_eff

        surplus_t0 < 0 && break

    end

    state.imbalance[t0] = surplus_t0

    return

end

function drawdown_soc!(state::DispatchState, prob::AdequacyParams, t::Int)
    for (s, stor) in enumerate(prob.storages)
        state.storage_soc[s] -= state.storage_dispatch[t, s] / stor.discharge_eff
    end
end

function backtrack_soc!(state::DispatchState, prob::AdequacyParams, t::Int)

    for (s, stor) in enumerate(prob.storages)
        dispatch = state.storage_dispatch[t,s]
        if dispatch > 0
            state.storage_soc[s] += dispatch / stor.discharge_eff
        else
            state.storage_soc[s] += dispatch * stor.charge_eff
        end
    end

end

# TODO: The control flow of the next three functions is pretty clunky & likely
#       not the most efficient, but good enough to prove the concept

function calc_duals_discharge_shortfall!(
    state::DispatchState, prob::AdequacyParams, t::Int)
    
    state.dEUE_generator[t] = 1.

    for (s, stor) in enumerate(prob.storages)
        
        if state.storage_dispatch[t,s] < stor.power_capacity
            
           state.dEUE_storage_energy[t,s] = stor.discharge_eff
           
        elseif state.storage_soc[s] < stor.energy_capacity
        
           next_dEUE_storage_energy =
               t == prob.n_timesteps ? 0 : state.dEUE_storage_energy[t+1, s]

           if next_dEUE_storage_energy > 0
               state.dEUE_storage_energy[t,s] = next_dEUE_storage_energy
           else
               state.dEUE_storage_discharge_limit[t,s] = stor.discharge_eff
           end

        else

           state.dEUE_storage_discharge_limit[t,s] = stor.discharge_eff
           state.dEUE_storage_energy_limit[t,s] =
               t == prob.n_timesteps ? 0 : state.dEUE_storage_energy[t+1, s]

        end

    end

end

function calc_duals_discharge_noshortfall!(
    state::DispatchState, prob::AdequacyParams, t::Int)

    # If the last period has no shortfall, its duals are always zero
    # (no potential to reduce current or future shortfall)
    t == prob.n_timesteps && return

    dEUE_max = 0

    for (s, stor) in enumerate(prob.storages)
        
        next_dEUE_storage_energy = state.dEUE_storage_energy[t+1,s]
        next_dEUE_storage_energy > 0 || continue

        if state.storage_soc[s] < stor.energy_capacity

            state.dEUE_storage_energy[t,s] = next_dEUE_storage_energy

            if state.storage_dispatch[t,s] > 0
                dEUE_max = max(dEUE_max, next_dEUE_storage_energy / stor.discharge_eff)
            end

        else

            state.dEUE_storage_energy_limit[t,s] = next_dEUE_storage_energy

        end

    end

    state.dEUE_generator[t] = dEUE_max

    return

end

function calc_duals_charge!(state::DispatchState, prob::AdequacyParams, t::Int)

    # If the last period has no shortfall, its duals are always zero
    # (no potential to reduce current or future shortfall)
    t == prob.n_timesteps && return

    dEUE_max = 0

    for (s, stor) in enumerate(prob.storages)
        
        next_dEUE_storage_energy = state.dEUE_storage_energy[t+1,s]
        next_dEUE_storage_energy > 0 || continue

        if state.storage_soc[s] < stor.energy_capacity

            state.dEUE_storage_energy[t,s] = next_dEUE_storage_energy

            if (-state.storage_dispatch[t,s] < stor.power_capacity)
                dEUE_max = max(dEUE_max, next_dEUE_storage_energy * stor.charge_eff)
            end

        else

            state.dEUE_storage_energy_limit[t,s] = next_dEUE_storage_energy

        end
        
    end

    state.dEUE_generator[t] = dEUE_max

    for (s, stor) in enumerate(prob.storages)

        charge_room_energy = state.storage_soc[s] < stor.energy_capacity
        charge_room_power = -state.storage_dispatch[t,s] < stor.power_capacity

        if charge_room_energy && !charge_room_power &&
            (state.dEUE_storage_energy[t,s] * stor.charge_eff > dEUE_max)

                state.dEUE_storage_charge_limit[t,s] =
                    state.dEUE_storage_energy[t,s] * stor.charge_eff - dEUE_max

        end

    end

    return

end

function record_primals!(
    results::ResultAccumulator, state::DispatchState, t::Int)
       
    shortfall = -state.imbalance[t]
    shortfall < 0 && return

    results.lolps[t] += 1.
    results.eues[t] += shortfall

    return

end

# This is pretty rough on the cache, probably best to either update these all
# at once at the end of the simulation, or on demand during duals calculation
# 
# Note that if we stop storing these explicitly we'll need to store them at
# each timestep, but that will be much easier on the cache since they won't
# be spread out in memory across a time dimension
function record_duals!(
    results::ResultAccumulator, state::DispatchState, t::Int)

    # Should eventually convert these checks to asserts or drop altogether

    state.dEUE_generator[t] < 0 &&
        error("Negative generation dual ($t, $s): $(state.dEUE_generator[t])")

    results.dEUE_generator[t] += state.dEUE_generator[t]
    
    for s in 1:state.n_storages
        
        state.dEUE_storage_charge_limit[t,s] < 0  &&
            error("Negative charge dual ($t, $s): $(state.dEUE_storage_charge_limit[t,s])")

        results.dEUE_storage_power[t,s] += state.dEUE_storage_charge_limit[t,s]
        
        state.dEUE_storage_discharge_limit[t,s] < 0 &&
            error("Negative discharge dual ($t, $s): $(state.dEUE_storage_discharge_limit[t,s])")

        results.dEUE_storage_power[t,s] += state.dEUE_storage_discharge_limit[t,s]

        state.dEUE_storage_energy_limit[t,s] < 0 &&
            error("Negative energy dual ($t, $s): $(state.dEUE_storage_energy_limit[t,s])")

        results.dEUE_storage_energy[t,s] += state.dEUE_storage_energy_limit[t,s]

    end

end

struct AdequacySimulationResult

    n_timesteps::Int
    n_storages::Int

    demand::Vector{Float64} # n_timesteps

    lolps::Vector{Float64} # n_timesteps
    eues::Vector{Float64} # n_timesteps

    generation_dEUEs::Vector{Float64} # n_timesteps
    storage_power_dEUEs::Matrix{Float64} # n_timesteps x n_storages
    storage_energy_dEUEs::Matrix{Float64} # n_timesteps x n_storages

    AdequacySimulationResult(prob::AdequacyParams, acc::ResultAccumulator) =
        new(
                prob.n_timesteps, prob.n_storages, prob.demand,
                acc.lolps / acc.n_samples,
                acc.eues / acc.n_samples,
                acc.dEUE_generator / acc.n_samples,
                acc.dEUE_storage_power / acc.n_samples,
                acc.dEUE_storage_energy / acc.n_samples
        )

end

neue(result::AdequacySimulationResult) = sum(result.eues) / sum(result.demand) * 1_000_000

function makesamples(samplestream::Channel{Int}, nsamples::Int)

    for s in 1:nsamples
        # print("\r", s)
        put!(samplestream, s)
    end

    close(samplestream)

end

function solve(prob::AdequacyParams; samples::Int, threaded::Bool=true)

    threads = nthreads()
    samplestream = Channel{Int}(2*threads)
    results = Channel{ResultAccumulator}(threads)
    
    @spawn makesamples(samplestream, samples)

    if threaded
        
        for _ in 1:threads
            @spawn solve_thread(prob, samplestream, results)
        end

        result = ResultAccumulator(prob)
        for _ in 1:threads
            other_result = take!(results)
            merge!(result, other_result)
        end
        close(results)

    else
        solve_thread(prob, samplestream, results)
        result = take!(results)
        close(results)
    end

    return AdequacySimulationResult(prob, result)

end

function solve_thread(
    prob::AdequacyParams,
    samplestream::Channel{Int}, results::Channel{ResultAccumulator})
    
    state = DispatchState(prob)
    acc = ResultAccumulator(prob)

    for s in samplestream
        solve_single!(state, acc, prob, s)
    end

    put!(results, acc)

    return

end
