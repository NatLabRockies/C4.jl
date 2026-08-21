module AdequacyModel

import Base: length, setindex!
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

export AdequacyProblem, AdequacyResult, solve, neue, neues, elcc,
    neue_estimates, eue_estimates, lole_estimates,
    neue_estimate, eue_estimate, lole_estimate

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

mutable struct DispatchYearAdequacyAccumulator

    n_samples::Int

    lolps::MeanVarianceVector # n_timesteps
    eues::MeanVarianceVector # n_timesteps

    lole::MeanVariance
    eue::MeanVariance

    generation_dEUEs::MeanVarianceVector # n_timesteps
    storage_power_dEUEs::MeanVarianceVector # n_storages
    storage_energy_dEUEs::MeanVarianceVector # n_storages

    function DispatchYearAdequacyAccumulator(n_timesteps::Int, n_storages::Int)

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
    result::DispatchYearAdequacyAccumulator, other::DispatchYearAdequacyAccumulator)

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

mutable struct InvestmentYearAdequacyAccumulator

    lolps::MeanVarianceVector # n_timesteps
    eues::MeanVarianceVector # n_timesteps

    lole_sum::Float64
    lole_sum_variance::Float64

    eue_sum::Float64
    eue_sum_variance::Float64

    generation_dEUEs::MeanVarianceVector # n_timesteps

    storage_power_dEUEs_sum::Vector{Float64} # n_storages
    storage_power_dEUEs_sum_variance::Vector{Float64}

    storage_energy_dEUEs_sum::Vector{Float64} # n_storages
    storage_energy_dEUEs_sum_variance::Vector{Float64}

    function InvestmentYearAdequacyAccumulator(
        n_timesteps::Int, n_storages::Int, n_samples::Int)

        lolps = MeanVarianceVector(n_timesteps)
        lolps.n = n_samples

        eues = MeanVarianceVector(n_timesteps)
        eues.n = n_samples

        generation_dEUEs = MeanVarianceVector(n_timesteps)
        generation_dEUEs.n = n_samples

        storage_power_dEUEs = zeros(n_storages)
        storage_power_dEUEs_variance = zeros(n_storages)

        storage_energy_dEUEs = zeros(n_storages)
        storage_energy_dEUEs_variance = zeros(n_storages)

        return new(lolps, eues, 0., 0., 0., 0., generation_dEUEs,
                   storage_power_dEUEs, storage_power_dEUEs_variance,
                   storage_energy_dEUEs, storage_energy_dEUEs_variance)

    end

end

function collect!(
    overall::InvestmentYearAdequacyAccumulator,
    subset::DispatchYearAdequacyAccumulator,
    range::UnitRange{Int})

    # Collect the subsetted time series data directly into the overall result

    overall.lolps[range] = subset.lolps
    overall.eues[range] = subset.eues
    overall.generation_dEUEs[range] = subset.generation_dEUEs

    # The following time-aggregated results and are assumed to be weighted
    # proportional to subset sample size, which, absent stratified sampling,
    # means uniformly across all subsets (note this is slightly inconsistent
    # with technology-level dEUE calculations elsewhere, which use the
    # concatenation of time series data stored above and so are implicitly
    # duration-weighted - the difference only matters when dispatch year
    # lengths are substantially different

    lole_mean, lole_var = mean_var(subset.lole)
    overall.lole_sum += lole_mean
    overall.lole_sum_variance += lole_var

    eue_mean, eue_var = mean_var(subset.eue)
    overall.eue_sum += eue_mean
    overall.eue_sum_variance += eue_var

    stor_power_dEUEs_mean, stor_power_dEUEs_var = mean_var(subset.storage_power_dEUEs)
    overall.storage_power_dEUEs_sum += stor_power_dEUEs_mean
    overall.storage_power_dEUEs_sum_variance += stor_power_dEUEs_var

    stor_energy_dEUEs_mean, stor_energy_dEUEs_var = mean_var(subset.storage_energy_dEUEs)
    overall.storage_energy_dEUEs_sum += stor_energy_dEUEs_mean
    overall.storage_energy_dEUEs_sum_variance += stor_energy_dEUEs_var

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
        prob::AdequacyProblem, results::Vector{InvestmentYearAdequacyAccumulator})

        n_days = n_dispatch_days(prob.sys.times)
        n_dispyears = n_dispatch_years(prob.sys.times)
        n_invyears = n_investment_years(prob.sys.times)

        # TODO: We assume this stays constant, which it does,
        #       but something cleaner would be nice
        n_storages = length(first(results).storage_power_dEUEs_sum)

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

            store_results!(lolps, lolps_stderr, result.lolps, i, n_days)
            store_results!(eues, eues_stderr, result.eues, i, n_days)

            lole[i] = result.lole_sum / n_dispyears
            lole_stdev_i = sqrt(result.lole_sum_variance) / n_dispyears
            lole_stderr[i] = lole_stdev_i / sqrt(prob.samples)

            eue[i] = result.eue_sum / n_dispyears
            eue_stdev_i = sqrt(result.eue_sum_variance) / n_dispyears
            eue_stderr[i] = eue_stdev_i / sqrt(prob.samples)

            store_results!(generation_dEUEs, generation_dEUEs_stderr,
                           result.generation_dEUEs, i, n_days)

            stor_power_dEUEs[:, i] = result.storage_power_dEUEs_sum / n_dispyears
            stor_power_dEUEs_stdev =
                sqrt.(result.storage_power_dEUEs_sum_variance) / n_dispyears
            stor_power_dEUEs_stderr[:, i] = stor_power_dEUEs_stdev / sqrt(prob.samples)

            stor_energy_dEUEs[:, i] = result.storage_energy_dEUEs_sum / n_dispyears
            stor_energy_dEUEs_stdev =
                sqrt.(result.storage_energy_dEUEs_sum_variance) / n_dispyears
            stor_energy_dEUEs_stderr[:, i] = stor_energy_dEUEs_stdev / sqrt(prob.samples)

        end

        # TODO: This is super ugly, we bake in the dispatch year averaging here
        #       to avoid passing the number of dispatch years around later.
        #       This means generator dEUE calculations can be done as the inner
        #       product of dEUE and generator availability alone. Clean this up!
        generation_dEUEs ./= n_dispyears
        generation_dEUEs_stderr ./= n_dispyears

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

function makeseeds(samples::Channel{Int}, n_samples::Int)

    for i in 1:n_samples
        put!(samples, i)
    end

    close(samples)

end

function solve_singlethreaded(
    prob::AdequacyProblem, params::AdequacyParams,
    samples::Channel{Int}, results::Channel{DispatchYearAdequacyAccumulator})

    opt = AdequacyOptimization(params, prob.optimizer)
    result = DispatchYearAdequacyAccumulator(params.n_timesteps, params.n_storages)

    ue_zero = 1e-6

    for i in samples

        sample_surplus!(opt, params, i)
        solve!(opt)

        result.n_samples += 1

        ues = unserved(opt)
        update!(result.eues, ues)
        update!(result.lolps, float.(ues .> ue_zero))

        update!(result.eue, sum(ues))
        update!(result.lole, float.(sum(ues .> ue_zero)))

        update!(result.generation_dEUEs, grid_dual(opt))
        update!(result.storage_power_dEUEs, stor_power_dual(opt))
        update!(result.storage_energy_dEUEs, stor_energy_dual(opt))

    end

    put!(results, result)

end

function solve(prob::AdequacyProblem)

    n_threads = prob.threaded ? nthreads() : 1

    n_invyears = n_investment_years(prob.sys.times)
    n_timesteps_total = n_dispatch_hours(prob.sys.times)
    n_storages = length(prob.sys.storagetechs_existing)

    results = Vector{InvestmentYearAdequacyAccumulator}(undef, n_invyears)

    println("Running RA checks...")

    for invyear in eachindex(results)

        result_invyear = InvestmentYearAdequacyAccumulator(
            n_timesteps_total, n_storages, prob.samples)

        for (d, d_range) in enumerate(dispatch_year_dayranges(prob.sys.times))

            println("Investment Year $invyear \t Dispatch Year $d")

            samples_in = Channel{Int}()
            results_out = Channel{DispatchYearAdequacyAccumulator}(n_threads)

            params = AdequacyParams(prob.sys, d_range, invyear)

            @spawn makeseeds(samples_in, prob.samples)

            if prob.threaded

                for _ in 1:n_threads
                    @spawn solve_singlethreaded(prob, params, samples_in, results_out)
                end

                result_out = take!(results_out)

                for _ in 2:n_threads
                    merge!(result_out, take!(results_out))
                end

                close(results_out)

            else

                solve_singlethreaded(prob, params, samples_in, results_out)
                result_out = take!(results_out)
                close(results_out)

            end

            # TODO: Eventually collect results directly out of results Channel?
            timesteps = dayrange_to_hourrange(d_range)
            collect!(result_invyear, result_out, timesteps)

        end

        results[invyear] = result_invyear

    end

    return AdequacyResult(prob, results)

end

avg_annual_energy(res::AdequacyResult, i::Int) =
    sum(res.demand[:, :, i]) / n_dispatch_years(res.times)

neue(res::AdequacyResult, i::Int) =
    res.eue[i] / avg_annual_energy(res, i) * 1_000_000

neues(res::AdequacyResult) =
    [neue(res, i) for i in 1:n_investment_years(res.times)]

lole_estimate(res::AdequacyResult, i::Int) = (res.lole[i], res.lole_stderr[i])

eue_estimate(res::AdequacyResult, i::Int) = (res.eue[i], res.eue_stderr[i])

neue_estimate(res::AdequacyResult, i::Int) =
    eue_estimate(res, i) ./ avg_annual_energy(res, i) .* 1_000_000

neue_estimates(res::AdequacyResult) =
    [neue_estimate(res, i) for i in 1:n_investment_years(res.times)]

include("elcc.jl")
include("export.jl")

end
