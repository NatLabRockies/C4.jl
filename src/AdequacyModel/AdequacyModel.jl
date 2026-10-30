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

export AdequacyProblem, AdequacyResult, solve, elcc, neue,
    neue_estimate, eue_estimate, lole_estimate

include("mean_variance.jl")

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

    lolps::MeanVarianceVector # n_timesteps
    eues::MeanVarianceVector # n_timesteps

    lole::MeanVariance
    eue::MeanVariance

    generation_dEUEs::MeanVarianceVector # n_timesteps
    storage_power_dEUEs::MeanVarianceVector # n_storages
    storage_energy_dEUEs::MeanVarianceVector # n_storages

    function SingleThreadAdequacyResult(prob::AdequacyProblem)

        lolps = MeanVarianceVector(prob.params.n_timesteps)
        eues = MeanVarianceVector(prob.params.n_timesteps)

        lole = MeanVariance()
        eue = MeanVariance()

        generation_dEUEs = MeanVarianceVector(prob.params.n_timesteps)
        storage_power_dEUEs = MeanVarianceVector(prob.params.n_storages)
        storage_energy_dEUEs = MeanVarianceVector(prob.params.n_storages)

        return new(0, lolps, eues, lole, eue,
                   generation_dEUEs, storage_power_dEUEs, storage_energy_dEUEs)

    end

end

function merge!(
    result::SingleThreadAdequacyResult, other::SingleThreadAdequacyResult)

    result.n_samples += other.n_samples

    merge!(result.lolps, other.lolps)
    merge!(result.eues, other.eues)

    merge!(result.lole, other.lole)
    merge!(result.eue, other.eue)

    merge!(result.generation_dEUEs, other.generation_dEUEs)
    merge!(result.storage_power_dEUEs, other.storage_power_dEUEs)
    merge!(result.storage_energy_dEUEs, other.storage_energy_dEUEs)

    return

end

struct AdequacyResult

    timestamps::StepRange{DateTime,Hour}

    demand::Vector{Float64}

    lolps::Vector{Float64} # n_timesteps
    lolps_stderr::Vector{Float64}

    eues::Vector{Float64} # n_timesteps
    eues_stderr::Vector{Float64}

    lole::Float64
    lole_stderr::Float64

    eue::Float64
    eue_stderr::Float64

    generation_dEUEs::Vector{Float64} # n_timesteps
    generation_dEUEs_stderr::Vector{Float64}

    storage_power_dEUEs::Vector{Float64} # n_storages
    storage_power_dEUEs_stderr::Vector{Float64}

    storage_energy_dEUEs::Vector{Float64} # n_storages
    storage_energy_dEUEs_stderr::Vector{Float64}

    function AdequacyResult(prob::AdequacyProblem, res::SingleThreadAdequacyResult)

        return new(
            prob.sys.timesteps, prob.params.demand,
            mean_stderr(res.lolps)..., mean_stderr(res.eues)...,
            mean_stderr(res.lole)..., mean_stderr(res.eue)...,
            mean_stderr(res.generation_dEUEs)...,
            mean_stderr(res.storage_power_dEUEs)...,
            mean_stderr(res.storage_energy_dEUEs)...)

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
        update!(result.eues, ues)
        update!(result.lolps, float.(ues .> 1e-3))

        update!(result.eue, sum(ues))
        update!(result.lole, float.(sum(ues .> 1e-3)))

        update!(result.generation_dEUEs, grid_dual(opt))
        update!(result.storage_power_dEUEs, stor_power_dual(opt))
        update!(result.storage_energy_dEUEs, stor_energy_dual(opt))

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

lole_estimate(res::AdequacyResult) = (res.lole, res.lole_stderr)
eue_estimate(res::AdequacyResult) = (res.eue, res.eue_stderr)
neue_estimate(res::AdequacyResult) = eue_estimate(res) ./ sum(res.demand) .* 1_000_000

include("elcc.jl")
include("export.jl")

end
