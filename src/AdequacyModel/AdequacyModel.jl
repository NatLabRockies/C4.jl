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
import ..powerunits_MW, ..maxpower, ..maxenergy, ..N_HOURS_IN_DAY,
       ..JuMP_LessThanConstraintRef, ..JuMP_EqualToConstraintRef, ..solve!

export AdequacyProblem, AdequacyResult, solve, neue, neues

include("AdequacyParams.jl")
include("AdequacyOptimization.jl")

struct AdequacyProblem

    sys::SystemParams

    optimizer::Any

    samples::Int
    threaded::Bool

    function AdequacyProblem(
        sys::SystemParams, optimizer;
        samples::Int, threaded::Bool=true)

        return new(sys, optimizer, samples, threaded)

    end

end

mutable struct SingleThreadAdequacyResult

    n_samples::Int

    lolps::Vector{Float64} # n_timesteps
    eues::Vector{Float64} # n_timesteps

    generation_dEUEs::Vector{Float64} # n_timesteps
    storage_power_dEUEs::Vector{Float64} # n_storages
    storage_energy_dEUEs::Vector{Float64} # n_storages

    function SingleThreadAdequacyResult(params::AdequacyParams)

        n_timesteps = params.n_timesteps
        n_storages = params.n_storages

        lolps = zeros(n_timesteps)
        eues = zeros(n_timesteps)

        generation_dEUEs = zeros(n_timesteps)
        storage_power_dEUEs = zeros(n_storages)
        storage_energy_dEUEs = zeros(n_storages)

        return new(
            0, lolps, eues,
            generation_dEUEs, storage_power_dEUEs, storage_energy_dEUEs)

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

    times::TimeIndices

    demand::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years
    lolps::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years
    eues::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years

    generation_dEUEs::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years
    storage_power_dEUEs::Matrix{Float64} # n_storages x n_investment_years
    storage_energy_dEUEs::Matrix{Float64} # n_storages x n_investment_years

    function AdequacyResult(
        prob::AdequacyProblem, results::Vector{SingleThreadAdequacyResult})

        n_days = n_dispatch_days(prob.sys.times)
        n_invyears = n_investment_years(prob.sys.times)
        n_storages = length(first(results).storage_power_dEUEs)

        lolps = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)
        eues = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)

        generation_dEUEs = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)
        stor_power_dEUEs = Matrix{Float64}(undef, n_storages, n_invyears)
        stor_energy_dEUEs = Matrix{Float64}(undef, n_storages, n_invyears)

        for (i, result) in enumerate(results)

            n = result.n_samples

            lolps[:, :, i] .=
                reshape(result.lolps, N_HOURS_IN_DAY, n_days) ./ n

            eues[:, :, i] .=
                reshape(result.eues, N_HOURS_IN_DAY, n_days) ./ n

            generation_dEUEs[:, :, i] .=
                reshape(result.generation_dEUEs, N_HOURS_IN_DAY, n_days) ./ n

            stor_power_dEUEs[:, i] .= result.storage_power_dEUEs ./ n

            stor_energy_dEUEs[:, i] .= result.storage_energy_dEUEs ./ n

        end

        return new(
            prob.sys.times, prob.sys.demand * powerunits_MW,
            lolps, eues, generation_dEUEs, stor_power_dEUEs, stor_energy_dEUEs)

    end

end


function makeseeds(samples::Channel{Int}, n_samples::Int)

    for i in 1:n_samples
        put!(samples, i)
    end

    close(samples)

end

function solve_singlethreaded(
    prob::AdequacyProblem, params::AdequacyParams,
    samples::Channel{Int}, results::Channel{SingleThreadAdequacyResult})

    opt = AdequacyOptimization(params, prob.optimizer)
    result = SingleThreadAdequacyResult(params)

    for i in samples

        sample_surplus!(opt, params, i)
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

    n_invyears = n_investment_years(prob.sys.times)
    results = Vector{SingleThreadAdequacyResult}(undef, n_invyears)

    for i in eachindex(results)

        samples_i = Channel{Int}()
        results_i = Channel{SingleThreadAdequacyResult}(n_threads)

        params = AdequacyParams(prob.sys, i)

        @spawn makeseeds(samples_i, prob.samples)

        if prob.threaded

            for _ in 1:n_threads
                @spawn solve_singlethreaded(prob, params, samples_i, results_i)
            end

            result_i = take!(results_i)

            for _ in 2:n_threads
                merge!(result_i, take!(results_i))
            end

            close(results_i)

        else

            solve_singlethreaded(prob, samples_i, results_i)
            result_i = take!(results_i)
            close(results_i)

        end

        results[i] = result_i

    end

    return AdequacyResult(prob, results)

end

neues(res::AdequacyResult) =
    [neue(res, i) for i in 1:n_investment_years(res.times)]

neue(res::AdequacyResult, i::Int) =
    sum(res.eues[:, :, i]) / sum(res.demand[:, :, i]) * 1_000_000

include("export.jl")

end
