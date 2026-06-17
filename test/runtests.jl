using Test
using Dates

using C4.Data
using C4.AdequacyModel
using C4.DispatchModel
using C4.ExpansionModel
using C4.IterationModel

import C4: store, powerunits_MW

using DuckDB

import HiGHS
import JuMP: optimizer_with_attributes, value, termination_status, write_to_file

include("DispatchModel/sequencing.jl")
include("AdequacySimulation.jl")
include("DispatchModel/thermal.jl")

optimizer = optimizer_with_attributes(
    HiGHS.Optimizer,
    "log_to_console" => false,
)

sys = SystemParams("Data/toysystem")
display(sys)

timestamp = Dates.format(now(), "yyyymmddHHMMSS")

fullchrono = fullchronologyperiods(sys)
repeatedchrono = singleperiod(sys)
null_eue = EUECuttingPlaneParams[]

voll = 9000.

pcm = DispatchProblem(sys, fullchrono, optimizer, voll=voll)
solve!(pcm)

# Note that ExpansionProblem takes its target in terms of
# unnormalized EUE and powerunits_MW!
# Nonzero values need to be scaled appropriately
# Here region.demand is already in powerunits_MW
max_eue = total_demand(sys) / 100_000 # 10 ppm

# For iterate_ra_cem, which takes NEUE
max_neue = 10.

ram = AdequacyProblem(sys, samples=1000)
ram_results = solve(ram)
println("\nBase NEUE = ", neue(ram_results))

# Formulate and solve a one-off CEM without risk curves

println("\n\nCopper sheet system, repeated chronology, manual iteration")

cem = ExpansionProblem(sys, repeatedchrono, null_eue, max_eue, NaN, NaN, optimizer)
write_to_file(cem.model, "model.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, samples=1000)
ram_results = solve(ram) # Dig into these results
println("\nNEUE = ", neue(ram_results))

eue_params = [EUECuttingPlaneParams(cem.builds, ram_results)]

cem = ExpansionProblem(sys, repeatedchrono, eue_params, max_eue, NaN, NaN, optimizer)
write_to_file(cem.model, "model_riskcurves_1.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, samples=1000)
ram_results = solve(ram)
println("\nNEUE = ", neue(ram_results))

push!(eue_params, EUECuttingPlaneParams(cem.builds, ram_results))

cem = ExpansionProblem(sys, repeatedchrono, eue_params, max_eue, NaN, NaN, optimizer)
write_to_file(cem.model, "model_riskcurves_2.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, samples=1000)
ram_results = solve(ram)
println("\nNEUE = ", neue(ram_results))

println("\nSingle-region Iterative CEM:")
cem, ram, pcm = iterate_ra_cem(
    sys, repeatedchrono, max_neue, optimizer,
    nsamples=100_000, check_dispatch=false, check_dispatch_voll=voll,
    outfile=timestamp * ".db", unit_commitment=true,
    max_co2_intensity=50., co2_offset_price=100.)

sys_built = SystemParams(cem)
display(sys_built)

println("NEUE: ", neue(ram))
println("Capex: ", value(capex(cem)))
println("Opex: ", value(opex(cem)))
println("Carbon Offsets Cost: ", value(carbon_offset_cost(cem)))
println()

println("System Cost: ", value(cost(cem)))
println("System LCOE: ", value(lcoe(cem)))
println("System Emissions Intensity: ", value(emissions_intensity(cem)))

ram = AdequacyProblem(sys_built, samples=100_000)
ram_results = solve(ram)
println("\nNEUE = ", neue(ram_results))

pcm = DispatchProblem(sys_built, repeatedchrono, optimizer, voll=voll,
                      unit_commitment=true)
solve!(pcm)
println("Operating Cost: ", value(cost(pcm)))
