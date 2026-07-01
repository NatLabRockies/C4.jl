module AdequacyModel

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
    params::Vector{AdequacyParams}
    opts::Vector{AdequacyOptimization}

    samples::Int

    function AdequacyProblem(sys::SystemParams, optimizer; samples::Int)

        params = Vector{AdequacyParams}(undef, n_investment_years(sys.times))
        opts = Vector{AdequacyOptimization}(undef, n_investment_years(sys.times))

        for i in eachindex(sys.times.investment_years)

            demand = vec(sys.demand[:, :, i]) .* powerunits_MW

            generators_capacity, generators_lambda, generators_mu =
                load_generators(sys, i)

            storages = load_storages(sys, i)

            params[i] = AdequacyParams(
                demand,
                generators_capacity, generators_lambda, generators_mu,
                storages)

            opts[i] = AdequacyOptimization(params[i], optimizer)

        end

        return new(sys, params, opts, samples)

    end

end

struct AdequacyResult

    times::TimeIndices

    demand::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years
    lolps::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years
    eues::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years

    generation_dEUEs::Array{Float64, 3} # N_HOURS_IN_DAY x n_days x n_investment_years
    storage_power_dEUEs::Matrix{Float64} # n_storages x n_investment_years
    storage_energy_dEUEs::Matrix{Float64} # n_storages x n_investment_years

end

function solve(prob::AdequacyProblem)

    # Note: We assume number of timesteps and storages is constant across all
    #       investment years, which is true, but isn't structurally
    #       guaranteed

    n_days = n_dispatch_days(prob.sys.times)
    n_invyears = n_investment_years(prob.sys.times)
    n_storages = first(prob.params).n_storages

    demand = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)
    lolps = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)
    eues = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)

    generation_dEUEs = Array{Float64, 3}(undef, N_HOURS_IN_DAY, n_days, n_invyears)
    stor_power_dEUE = Matrix{Float64}(undef, n_storages, n_invyears)
    stor_energy_dEUE = Matrix{Float64}(undef, n_storages, n_invyears)

    for (i, (params, opt)) in enumerate(zip(prob.params, prob.opts))

        lolps_i = zeros(params.n_timesteps)
        eues_i = zeros(params.n_timesteps)

        dEUEs_grid = zeros(params.n_timesteps)
        dEUEs_stor_power = zeros(params.n_storages)
        dEUEs_stor_energy = zeros(params.n_storages)

        for s in 1:prob.samples

            sample_surplus!(opt, params, s)
            solve!(opt)

            ues = unserved(opt)
            eues_i .+= ues
            lolps_i .+= ues .> 1e-3

            dEUEs_grid .+= grid_dual(opt)
            dEUEs_stor_power .+= stor_power_dual(opt)
            dEUEs_stor_energy .+= stor_energy_dual(opt)

        end

        lolps_i ./= prob.samples
        eues_i ./= prob.samples

        dEUEs_grid ./= prob.samples
        dEUEs_stor_power ./= prob.samples
        dEUEs_stor_energy ./= prob.samples

        demand[:, :, i] = reshape(params.demand, N_HOURS_IN_DAY, n_days)
        lolps[:, :, i] = reshape(lolps_i, N_HOURS_IN_DAY, n_days)
        eues[:, :, i] = reshape(eues_i, N_HOURS_IN_DAY, n_days)

        generation_dEUEs[:, :, i] = reshape(dEUEs_grid, N_HOURS_IN_DAY, n_days)
        stor_power_dEUE[:, i] = dEUEs_stor_power
        stor_energy_dEUE[:, i] = dEUEs_stor_energy

    end

    return AdequacyResult(
        prob.sys.times, demand, lolps, eues,
        generation_dEUEs, stor_power_dEUE, stor_energy_dEUE)

end

neues(res::AdequacyResult) =
    [neue(res, i) for i in 1:n_investment_years(res.times)]

neue(res::AdequacyResult, i::Int) =
    sum(res.eues[:, :, i]) / sum(res.demand[:, :, i]) * 1_000_000

include("export.jl")

end
