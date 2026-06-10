import Base.Threads: nthreads, @spawn

import Random: rand, seed!
import Random123: Philox4x

const zero_range = sqrt(eps())

struct GeneratorParams
    capacity::Float64
    lambda::Float64
    mu::Float64
end

struct StorageParams
    charge_eff::Float64
    discharge_eff::Float64
    power_capacity::Float64
    energy_capacity::Float64
end

struct AdequacyParams

    n_timesteps::Int
    n_generators::Int
    n_storages::Int

    demand::Vector{Float64} # n_timesteps

    generators::Matrix{GeneratorParams} # n_generators x n_timesteps

    # Note: Provided storages MUST be pre-sorted by round-trip efficiency
    storages::Vector{StorageParams} # n_storages

    function AdequacyParams(
        demand::Vector{Float64},
        generators::Matrix{GeneratorParams},
        storages::Vector{StorageParams})

        n_timesteps = length(demand)
        n_generators = size(generators, 1)
        n_storages = length(storages)

        size(generators, 2) == n_timesteps || error("Inconsistent number of timesteps")
        # TODO: Verify round-trip efficiency sorting

        new(n_timesteps, n_generators, n_storages, demand, generators, storages)

    end

end

struct DispatchState

    n_timesteps::Int
    n_storages::Int

    imbalance_prestorage::Vector{Float64} # n_timesteps - hacky but fine for now
    imbalance::Vector{Float64} # n_timesteps
    shortfalls::Vector{Float64} # n_timesteps - per-sample shortfall scratch
    
    generator_availability::Vector{Bool} # n_generators
    
    storage_soc::Vector{Float64} # n_storages
    storage_dispatch::Matrix{Float64}  # n_timesteps x n_storages

    dEUE_generator::Vector{Float64} # n_timesteps
    dEUE_storage_energy::Matrix{Float64} # n_timesteps x n_storages
    
    dEUE_storage_charge_limit::Matrix{Float64} # n_timesteps x n_storages
    dEUE_storage_discharge_limit::Matrix{Float64} # n_timesteps x n_storages
    dEUE_storage_energy_limit::Matrix{Float64} # n_timesteps x n_storages

    function DispatchState(prob::AdequacyParams)
        
        new(
        
            prob.n_timesteps, prob.n_storages,
            
            Vector{Float64}(undef, prob.n_timesteps),
            Vector{Float64}(undef, prob.n_timesteps),
            zeros(prob.n_timesteps),
            
            Vector{Bool}(undef, prob.n_generators),
            
            Vector{Float64}(undef, prob.n_storages),
            Matrix{Float64}(undef, prob.n_timesteps, prob.n_storages),
            
            Vector{Float64}(undef, prob.n_timesteps),
            Matrix{Float64}(undef, prob.n_timesteps, prob.n_storages),
            
            Matrix{Float64}(undef, prob.n_timesteps, prob.n_storages),
            Matrix{Float64}(undef, prob.n_timesteps, prob.n_storages),
            Matrix{Float64}(undef, prob.n_timesteps, prob.n_storages)

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

    shortfall_samples::Vector{Vector{Float64}} # n_samples, each of length n_timesteps
    storage_power_samples::Vector{Vector{Float64}} # n_samples, each of length n_storages
    storage_energy_samples::Vector{Vector{Float64}} # n_samples, each of length n_storages

    ResultAccumulator(prob::AdequacyParams) =
        new(prob.n_timesteps, 0,
            zeros(prob.n_timesteps), zeros(prob.n_timesteps),
            zeros(prob.n_timesteps),
            zeros(prob.n_timesteps, prob.n_storages),
            zeros(prob.n_timesteps, prob.n_storages),
            Vector{Vector{Float64}}(),
            Vector{Vector{Float64}}(),
            Vector{Vector{Float64}}()
        )

end

function merge!(acc1::ResultAccumulator, acc2::ResultAccumulator)

    acc1.n_samples += acc2.n_samples

    acc1.lolps .+= acc2.lolps
    acc1.eues .+= acc2.eues

    acc1.dEUE_generator .+= acc2.dEUE_generator
    acc1.dEUE_storage_power .+= acc2.dEUE_storage_power
    acc1.dEUE_storage_energy .+= acc2.dEUE_storage_energy

    append!(acc1.shortfall_samples, acc2.shortfall_samples)
    append!(acc1.storage_power_samples, acc2.storage_power_samples)
    append!(acc1.storage_energy_samples, acc2.storage_energy_samples)

    return

end

function solve_single!(
    state::DispatchState, results::ResultAccumulator,
    prob::AdequacyParams, sample_idx::Int)
    
        initialize!(state, prob, sample_idx)
        results.n_samples += 1
        # println(state.imbalance_prestorage)

        for t in 1:prob.n_timesteps
            
            if state.imbalance[t] > zero_range
                shift_energy_forward!(state, prob, t)
            else
                drawdown_soc!(state, prob, t)
                record_primals!(results, state, t)
            end

        end

        for t in prob.n_timesteps:-1:1

            if state.imbalance[t] < -zero_range
                calc_duals_discharge_shortfall!(state, prob, t)
            elseif state.imbalance_prestorage[t] < -zero_range
                calc_duals_discharge_noshortfall!(state, prob, t)
            else
                calc_duals_charge!(state, prob, t)
            end

            backtrack_soc!(state, prob, t)
            record_duals!(results, state, t)

        end

        # check_strong_duality(prob, state)

        # Store per-sample per-timestep shortfalls for CVaR computation
        push!(results.shortfall_samples, copy(state.shortfalls))

        # Store per-sample storage duals (summed over timesteps) for CVaR computation
        push!(results.storage_power_samples,
            [sum(state.dEUE_storage_charge_limit[:,s] .+
                 state.dEUE_storage_discharge_limit[:,s]) for s in 1:prob.n_storages])
        push!(results.storage_energy_samples,
            [sum(state.dEUE_storage_energy_limit[:,s]) for s in 1:prob.n_storages])

        return

end

function check_strong_duality(prob::AdequacyParams, state::DispatchState)
    
    primal_objval = sum(-sp for sp in state.imbalance if sp < -zero_range; init=0.)

    dEUE_charge_power = vec(sum(state.dEUE_storage_charge_limit, dims=1))
    dEUE_discharge_power = vec(sum(state.dEUE_storage_discharge_limit, dims=1))
    dEUE_energy = vec(sum(state.dEUE_storage_energy_limit, dims=1))
        
    dual_objval = -sum(
        dEUE_chg_p * stor.power_capacity +
        dEUE_dchg_p * stor.power_capacity/stor.discharge_eff +
        dEUE_e * stor.energy_capacity
        for (dEUE_chg_p, dEUE_dchg_p, dEUE_e, stor)
        in zip(dEUE_charge_power, dEUE_discharge_power, dEUE_energy, prob.storages); init=0.) -
        sum(state.imbalance_prestorage .* state.dEUE_generator)

    if !isapprox(primal_objval, dual_objval)
        error("Strong duality violation - primal = $primal_objval, dual = $dual_objval")
    end

end

function initialize!(state::DispatchState, prob::AdequacyParams, sample_idx::Int)
    
    sample_surplus!(state, prob, sample_idx)
    
    fill!(state.shortfalls, 0.)
    fill!(state.storage_soc, 0.)
    fill!(state.storage_dispatch, 0.)
    
    fill!(state.dEUE_generator, 0.)
    fill!(state.dEUE_storage_energy, 0.)
    
    fill!(state.dEUE_storage_charge_limit, 0.)
    fill!(state.dEUE_storage_discharge_limit, 0.)
    fill!(state.dEUE_storage_energy_limit, 0.)

    return

end

function sample_surplus!(state::DispatchState, prob::AdequacyParams, sample_idx::Int)

    rng = Philox4x((sample_idx, sample_idx), 10)

    # TODO: Update counter predictably based on g (generator name hash?) and t.
    #       For now we just use automatic incrementing

    for (g, gen) in enumerate(prob.generators[:, 1])
        longrun_availability = gen.mu / (gen.lambda + gen.mu)
        state.generator_availability[g] = rand(rng) < longrun_availability
    end

    for t in 1:prob.n_timesteps

        surplus = -prob.demand[t]

        for g in 1:prob.n_generators

            gen = prob.generators[g,t]
            draw = rand(rng)

            if state.generator_availability[g]
                (draw < gen.lambda) && (state.generator_availability[g] = false)
            elseif draw < gen.mu
                state.generator_availability[g] = true
            end

            state.generator_availability[g] && (surplus += gen.capacity)

        end

        state.imbalance[t] = surplus

    end

    state.imbalance_prestorage .= state.imbalance

    return

end

function shift_energy_forward!(
    state::DispatchState, prob::AdequacyParams, t0::Int)

    surplus_t0 = state.imbalance[t0]
    
    for (s, stor) in enumerate(prob.storages)
        
        max_chargeable_t0 = min(
            surplus_t0, stor.power_capacity,
            (stor.energy_capacity - state.storage_soc[s]) / stor.charge_eff)
            
        charge_t0 = 0.

        for t in (t0+1):prob.n_timesteps

            shortfall_t = -state.imbalance[t] 
            shortfall_t < zero_range && continue

            discharge_t = min(
                shortfall_t,
                stor.power_capacity - state.storage_dispatch[t, s],
                (max_chargeable_t0 - charge_t0) * stor.charge_eff * stor.discharge_eff)

            state.storage_dispatch[t, s] += discharge_t
            state.imbalance[t] += discharge_t

            charge_t0_t = discharge_t / stor.charge_eff / stor.discharge_eff

            charge_t0 += charge_t0_t
            surplus_t0 -= charge_t0_t

            (charge_t0 < max_chargeable_t0 - zero_range) || break

        end
        
        state.storage_dispatch[t0, s] = -charge_t0
        state.storage_soc[s] += charge_t0 * stor.charge_eff

        surplus_t0 < zero_range && break

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
        if dispatch > zero_range
            state.storage_soc[s] += dispatch / stor.discharge_eff
        elseif dispatch < -zero_range
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
        
        if state.storage_dispatch[t,s] < stor.power_capacity - zero_range
            
           state.dEUE_storage_energy[t,s] = stor.discharge_eff
           
        elseif state.storage_soc[s] < stor.energy_capacity - zero_range
        
           next_dEUE_storage_energy =
               t == prob.n_timesteps ? 0 : state.dEUE_storage_energy[t+1, s]

           if next_dEUE_storage_energy > zero_range 
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
        next_dEUE_storage_energy > zero_range || continue

        if state.storage_soc[s] < stor.energy_capacity - zero_range

            state.dEUE_storage_energy[t,s] = next_dEUE_storage_energy

            if state.storage_dispatch[t,s] > zero_range
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
        next_dEUE_storage_energy > zero_range || continue

        if state.storage_soc[s] > stor.energy_capacity - zero_range

            state.dEUE_storage_energy_limit[t,s] = next_dEUE_storage_energy

        else

            state.dEUE_storage_energy[t,s] = next_dEUE_storage_energy

            if (-state.storage_dispatch[t,s] < stor.power_capacity - zero_range)
                dEUE_max = max(dEUE_max, next_dEUE_storage_energy * stor.charge_eff)
            end

        end
        
    end

    state.dEUE_generator[t] = dEUE_max

    for (s, stor) in enumerate(prob.storages)

        charge_room_energy = state.storage_soc[s] < stor.energy_capacity - zero_range
        charge_room_power = -state.storage_dispatch[t,s] < stor.power_capacity - zero_range

        if charge_room_energy && !charge_room_power &&
            (state.dEUE_storage_energy[t,s] * stor.charge_eff > dEUE_max + zero_range)

                state.dEUE_storage_charge_limit[t,s] =
                    state.dEUE_storage_energy[t,s] * stor.charge_eff - dEUE_max

        end

    end

    return

end

function record_primals!(
    results::ResultAccumulator, state::DispatchState, t::Int)
       
    shortfall = -state.imbalance[t]
    shortfall < zero_range && return

    results.lolps[t] += 1.
    results.eues[t] += shortfall
    state.shortfalls[t] = shortfall

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

    if state.dEUE_generator[t] < -zero_range
        error("Negative generation dual ($t, $s): $(state.dEUE_generator[t])")
    elseif state.dEUE_generator[t] > zero_range
        results.dEUE_generator[t] += state.dEUE_generator[t]
    end
    
    for s in 1:state.n_storages
        
        if state.dEUE_storage_charge_limit[t,s] < -zero_range
            error("Negative charge dual ($t, $s): $(state.dEUE_storage_charge_limit[t,s])")
        elseif state.dEUE_storage_charge_limit[t,s] > zero_range
            results.dEUE_storage_power[t,s] += state.dEUE_storage_charge_limit[t,s]
        end
        
        if state.dEUE_storage_discharge_limit[t,s] < -zero_range
            error("Negative discharge dual ($t, $s): $(state.dEUE_storage_discharge_limit[t,s])")
        elseif state.dEUE_storage_discharge_limit[t,s] > zero_range
            results.dEUE_storage_power[t,s] += state.dEUE_storage_discharge_limit[t,s]
        end

        if state.dEUE_storage_energy_limit[t,s] < -zero_range
            error("Negative energy dual ($t, $s): $(state.dEUE_storage_energy_limit[t,s])")
        elseif state.dEUE_storage_energy_limit[t,s] > zero_range
            results.dEUE_storage_energy[t,s] += state.dEUE_storage_energy_limit[t,s]
        end

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

    shortfall_samples::Matrix{Float64} # n_timesteps × n_samples
    storage_power_samples::Matrix{Float64} # n_storages × n_samples
    storage_energy_samples::Matrix{Float64} # n_storages × n_samples

    AdequacySimulationResult(prob::AdequacyParams, acc::ResultAccumulator) =
        new(
                prob.n_timesteps, prob.n_storages, prob.demand,
                acc.lolps / acc.n_samples,
                acc.eues / acc.n_samples,
                acc.dEUE_generator / acc.n_samples,
                acc.dEUE_storage_power / acc.n_samples,
                acc.dEUE_storage_energy / acc.n_samples,
                reduce(hcat, acc.shortfall_samples),
                reduce(hcat, acc.storage_power_samples),
                reduce(hcat, acc.storage_energy_samples)
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

function solve(prob::AdequacyParams; samples::Int)

    threads = nthreads()
    samplestream = Channel{Int}(2*threads)
    results = Channel{ResultAccumulator}(threads)
    
    @spawn makesamples(samplestream, samples)

    threaded = true
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
