module AdequacyModel

import Base: length
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

export AdequacyProblem, AdequacyResult, solve, neue, neues,
    neue_estimates, eue_estimates, lole_estimates

include("mean_variance.jl")

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

    lolps::MeanVarianceVector # n_timesteps
    eues::MeanVarianceVector # n_timesteps

    lole::MeanVariance
    eue::MeanVariance

    generation_dEUEs::MeanVarianceVector # n_timesteps
    storage_power_dEUEs::MeanVarianceVector # n_storages
    storage_energy_dEUEs::MeanVarianceVector # n_storages

    function SingleThreadAdequacyResult(params::AdequacyParams)

        n_timesteps = params.n_timesteps
        n_storages = params.n_storages

        lolps = MeanVarianceVector(n_timesteps)
        eues = MeanVarianceVector(n_timesteps)

        lole = MeanVariance()
        eue = MeanVariance()

        generation_dEUEs = MeanVarianceVector(n_timesteps)
        storage_power_dEUEs = MeanVarianceVector(n_storages)
        storage_energy_dEUEs = MeanVarianceVector(n_storages)

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

    times::TimeIndices

    demand::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years

    lolps::Array{Float64, 3}  # N_HOURS_IN_DAY x n_days x n_investment_years
    lolps_stderr::Array{Float64, 3}

    eues::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years
    eues_stderr::Array{Float64, 3}

    lole::Vector{Float64} # n_investment_years
    lole_stderr::Vector{Float64}

    eue::Vector{Float64} # n_investment_years
    eue_stderr::Vector{Float64}

    generation_dEUEs::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years
    generation_dEUEs_stderr::Array{Float64, 3}

    storage_power_dEUEs::Matrix{Float64} # n_storages x n_investment_years
    storage_power_dEUEs_stderr::Matrix{Float64}

    storage_energy_dEUEs::Matrix{Float64} # n_storages x n_investment_years
    storage_energy_dEUEs_stderr::Matrix{Float64}

    function AdequacyResult(
        prob::AdequacyProblem, results::Vector{SingleThreadAdequacyResult})

        n_days = n_dispatch_days(prob.sys.times)
        n_invyears = n_investment_years(prob.sys.times)

        # TODO: We assume this stays constant, which it does,
        #       but something cleaner would be nice
        n_storages = length(first(results).storage_power_dEUEs)

        lolps = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)
        lolps_stderr = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)

        eues = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)
        eues_stderr = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)

        lole = Vector{Float64}(undef, n_invyears)
        lole_stderr = Vector{Float64}(undef, n_invyears)

        eue = Vector{Float64}(undef, n_invyears)
        eue_stderr = Vector{Float64}(undef, n_invyears)

        generation_dEUEs = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)
        generation_dEUEs_stderr = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)

        stor_power_dEUEs = Matrix{Float64}(undef, n_storages, n_invyears)
        stor_power_dEUEs_stderr = Matrix{Float64}(undef, n_storages, n_invyears)

        stor_energy_dEUEs = Matrix{Float64}(undef, n_storages, n_invyears)
        stor_energy_dEUEs_stderr = Matrix{Float64}(undef, n_storages, n_invyears)

        for (i, result) in enumerate(results)

            n = result.n_samples

            store_results!(lolps, lolps_stderr, result.lolps, i, n_days)
            store_results!(eues, eues_stderr, result.eues, i, n_days)

            store_results!(lole, lole_stderr, result.lole, i)
            store_results!(eue, eue_stderr, result.eue, i)

            store_results!(generation_dEUEs, generation_dEUEs_stderr,
                           result.generation_dEUEs, i, n_days)

            store_results!(stor_power_dEUEs, stor_power_dEUEs_stderr,
                           result.storage_power_dEUEs, i)

            store_results!(stor_energy_dEUEs, stor_energy_dEUEs_stderr,
                           result.storage_energy_dEUEs, i)

        end

        return new(
            prob.sys.times, prob.sys.demand * powerunits_MW,
            lolps, lolps_stderr, eues, eues_stderr,
            lole, lole_stderr, eue, eue_stderr,
            generation_dEUEs, generation_dEUEs_stderr,
            stor_power_dEUEs, stor_power_dEUEs_stderr,
            stor_energy_dEUEs, stor_energy_dEUEs_stderr)

    end

end

function store_results!(
    dst_mean::Array{Float64, 3}, dst_std::Array{Float64, 3},
    src::MeanVarianceVector, invyear::Int, n_days::Int)

   src_mean, src_std = mean_stderr(src)

   dst_mean[:, :, invyear] = reshape(src_mean, N_HOURS_IN_DAY, n_days)
   dst_std[:, :, invyear] = reshape(src_std, N_HOURS_IN_DAY, n_days)

   return

end

function store_results!(
    dst_mean::Matrix{Float64}, dst_std::Matrix{Float64},
    src::MeanVarianceVector, invyear::Int)

   src_mean, src_std = mean_stderr(src)

   dst_mean[:, invyear] = src_mean
   dst_std[:, invyear] = src_std

   return

end

function store_results!(
    dst_mean::Vector{Float64}, dst_std::Vector{Float64},
    src::MeanVariance, invyear::Int)

   src_mean, src_std = mean_stderr(src)

   dst_mean[invyear] = src_mean
   dst_std[invyear] = src_std

   return

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

            solve_singlethreaded(prob, params, samples_i, results_i)
            result_i = take!(results_i)
            close(results_i)

        end

        results[i] = result_i

    end

    return AdequacyResult(prob, results)

end

neue(res::AdequacyResult, i::Int) =
    res.eue[i] / sum(res.demand[:, :, i]) * 1_000_000

neues(res::AdequacyResult) =
    [neue(res, i) for i in 1:n_investment_years(res.times)]

lole_estimate(res::AdequacyResult, i::Int) = (res.lole[i], res.lole_stderr[i])

eue_estimate(res::AdequacyResult, i::Int) = (res.eue[i], res.eue_stderr[i])

neue_estimate(res::AdequacyResult, i::Int) =
    eue_estimate(res, i) ./ sum(res.demand[:, :, i]) .* 1_000_000

neue_estimates(res::AdequacyResult) =
    [neue_estimate(res, i) for i in 1:n_investment_years(res.times)]

include("export.jl")

end
