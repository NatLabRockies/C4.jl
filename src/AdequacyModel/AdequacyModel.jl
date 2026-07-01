module AdequacyModel

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
    opt::AdequacyOptimization

    samples::Int

    function AdequacyProblem(sys::SystemParams, optimizer; samples::Int)

        demand = sys.demand .* powerunits_MW

        generators_capacity, generators_lambda, generators_mu =
            load_generators(sys)

        storages = load_storages(sys)

        params = AdequacyParams(
            demand,
            generators_capacity, generators_lambda, generators_mu,
            storages)

        opt = AdequacyOptimization(params, optimizer)

        return new(sys, params, opt, samples)

    end

end

struct AdequacyResult

    timestamps::StepRange{DateTime,Hour}

    demand::Vector{Float64}
    lolps::Vector{Float64}
    eues::Vector{Float64}

    generation_dEUEs::Vector{Float64} # n_timesteps
    storage_power_dEUEs::Vector{Float64} # n_storages
    storage_energy_dEUEs::Vector{Float64} # n_storages

end

function solve(prob::AdequacyProblem)

    lolps = zeros(prob.params.n_timesteps)
    eues = zeros(prob.params.n_timesteps)

    dEUEs_grid = zeros(prob.params.n_timesteps)
    dEUEs_stor_power = zeros(prob.params.n_storages)
    dEUEs_stor_energy = zeros(prob.params.n_storages)

    for i in 1:prob.samples

        sample_surplus!(prob.opt, prob.params, i)
        solve!(prob.opt)

        ues = unserved(prob.opt)
        eues .+= ues
        lolps .+= ues .> 1e-3

        dEUEs_grid .+= grid_dual(prob.opt)
        dEUEs_stor_power .+= stor_power_dual(prob.opt)
        dEUEs_stor_energy .+= stor_energy_dual(prob.opt)

    end

    lolps ./= prob.samples
    eues ./= prob.samples

    dEUEs_grid ./= prob.samples
    dEUEs_stor_power ./= prob.samples
    dEUEs_stor_energy ./= prob.samples

    return AdequacyResult(
        prob.sys.timesteps,
        prob.params.demand, lolps, eues,
        dEUEs_grid, dEUEs_stor_power, dEUEs_stor_energy)

end

neue(res::AdequacyResult) = sum(res.eues) / sum(res.demand) * 1_000_000

include("export.jl")

end
