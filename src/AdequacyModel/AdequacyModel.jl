module AdequacyModel

import Base.Threads: nthreads, @spawn

import Dates: DateTime, Hour
import Random: rand, seed!, AbstractRNG

import JuMP
import JuMP: @variable, @constraint, @expression, @objective,
             value, shadow_price, reduced_cost, UpperBoundRef,
             set_normalized_rhs

import Random123: Philox4x

using ..Data
import ..powerunits_MW, ..ThermalTechnology, ..maxpower, ..maxenergy,
       ..JuMP_LessThanConstraintRef, ..JuMP_EqualToConstraintRef, ..solve!

export AdequacyProblem, AdequacyResult, solve, neue, show_neues

include("AdequacyParams.jl")
include("AdequacyOptimization.jl")

struct AdequacyProblem

    sys::SystemParams
    params::AdequacyParams
    optimizer::Any

    samples::Int
    threaded::Bool

    function AdequacyProblem(sys::SystemParams, optimizer;
        samples::Int, threaded::Bool=true)

        demand = sys.demand .* powerunits_MW

        generators_capacity, generators_lambda, generators_mu =
            load_generators(sys)

        storages = load_storages(sys)

        params = AdequacyParams(
            demand,
            generators_capacity, generators_lambda, generators_mu,
            storages)

        return new(sys, params, optimizer, samples, threaded)

    end

end

mutable struct SingleThreadAdequacyResult

    n_samples::Int

    lolps::Vector{Float64} # n_timesteps
    eues::Vector{Float64} # n_timesteps

    generation_dEUEs::Vector{Float64} # n_timesteps
    storage_power_dEUEs::Vector{Float64} # n_storages
    storage_energy_dEUEs::Vector{Float64} # n_storages

    function SingleThreadAdequacyResult(prob::AdequacyProblem)

        lolps = zeros(prob.params.n_timesteps)
        eues = zeros(prob.params.n_timesteps)

        generation_dEUEs = zeros(prob.params.n_timesteps)
        storage_power_dEUEs = zeros(prob.params.n_storages)
        storage_energy_dEUEs = zeros(prob.params.n_storages)

        return new(0, lolps, eues,
                   generation_dEUEs,
                   storage_power_dEUEs, storage_energy_dEUEs)

    end

end

function merge!(
    result::SingleThreadAdequacyResult, other::SingleThreadAdequacyResult)

    result.n_samples += other.n_samples

    result.lolps += other.lolps
    result.eues += other.eues

    result.generation_dEUEs += other.generation_dEUEs
    result.storage_power_dEUEs += other.storage_power_dEUEs
    result.storage_energy_dEUEs += other.storage_energy_dEUEs

    return

end

struct AdequacyResult

    timestamps::StepRange{DateTime,Hour}

    demand::Vector{Float64}
    lolps::Vector{Float64}
    eues::Vector{Float64}

    generation_dEUEs::Vector{Float64} # n_timesteps
    storage_power_dEUEs::Vector{Float64} # n_storages
    storage_energy_dEUEs::Vector{Float64} # n_storages

    function AdequacyResult(prob::AdequacyProblem, res::SingleThreadAdequacyResult)

        return new(
            prob.sys.timesteps, prob.params.demand,
            res.lolps / res.n_samples, res.eues / res.n_samples,
            res.generation_dEUEs / res.n_samples,
            res.storage_power_dEUEs / res.n_samples,
            res.storage_energy_dEUEs / res.n_samples)

    end

end


function makeseeds(samples::Channel{Int}, n_samples::Int)

    for i in 1:n_samples
        put!(samples, i)
    end

    close(samples)

end

function solve_singlethreaded(
    prob::AdequacyProblem,
    samples::Channel{Int}, results::Channel{SingleThreadAdequacyResult})

    opt = AdequacyOptimization(prob.params, prob.optimizer)
    result = SingleThreadAdequacyResult(prob)

    for i in samples

        sample_surplus!(opt, prob.params, i)
        solve!(opt)

        result.n_samples += 1

        ues = unserved(opt)
        result.eues .+= ues
        result.lolps .+= ues .> 1e-3

        result.generation_dEUEs .+= grid_dual(opt)
        result.storage_power_dEUEs .+= stor_power_dual(opt)
        result.storage_energy_dEUEs .+= stor_energy_dual(opt)

    end

    put!(results, result)

end

function solve(prob::AdequacyProblem)

    n_threads = prob.threaded ? nthreads() : 1

    samples = Channel{Int}()
    results = Channel{SingleThreadAdequacyResult}(n_threads)

    @spawn makeseeds(samples, prob.samples)

    if prob.threaded

        for _ in 1:n_threads
            @spawn solve_singlethreaded(prob, samples, results)
        end

        result = take!(results)

        for _ in 2:n_threads
            thread_result = take!(results)
            merge!(result, thread_result)
        end

        close(results)

    else

        solve_singlethreaded(prob, samples, results)
        result = take!(results)
        close(results)

    end

    return AdequacyResult(prob, result)

end

neue(res::AdequacyResult) = sum(res.eues) / sum(res.demand) * 1_000_000

include("export.jl")

end
