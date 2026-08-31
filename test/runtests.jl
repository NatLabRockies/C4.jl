using Test
using Dates

using C4.Data
using C4.AdequacyModel
using C4.DispatchModel
using C4.ExpansionModel
using C4.IterationModel

import C4: store, powerunits_MW
import C4.ExpansionModel: cost_capex, cost_fom
import C4.DispatchModel: generation_cost, co2_offset_cost

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

sys = SystemParams("Data/toysystem", opex_endyears=10)
display(sys)

timestamp = Dates.format(now(), "yyyymmddHHMMSS")

fullchrono = fullchronologyperiods(sys)

repeatedchrono = [singleperiod(sys, i)
                  for i in eachindex(sys.times.investment_years)]

null_eue = [EUECuttingPlaneParams[], EUECuttingPlaneParams[]]

voll = 9000.

pcm = DispatchProblem(sys, 1, fullchrono, optimizer, voll=voll)
solve!(pcm)

# Note that ExpansionProblem takes its target in terms of
# unnormalized EUE and powerunits_MW!
# Nonzero values need to be scaled appropriately
# Here total_demand is already in powerunits_MW
max_eues = [
    total_demand(sys, 1) / 100_000 # 2030 10 ppm
    total_demand(sys, 2) / 100_000 # 2050 10 ppm
]

# For iterate_ra_cem, which takes NEUE
max_neue = 10.

ram = AdequacyProblem(sys, samples=1000)
ram_results = solve(ram)
println("\nBase NEUEs = ", neues(ram_results))

# Formulate and solve a one-off CEM without risk curves

println("\n\nCopper sheet system, repeated chronology, manual iteration")

cem = ExpansionProblem(sys, repeatedchrono, null_eue, max_eues, optimizer)
write_to_file(cem.model, "model.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, samples=1000)
ram_results = solve(ram) # Dig into these results
println("\nNEUEs = ", neues(ram_results))

eue_params = [[EUECuttingPlaneParams(cem.builds, ram_results, i)] for i in 1:2]

cem = ExpansionProblem(sys, repeatedchrono, eue_params, max_eues, optimizer)
write_to_file(cem.model, "model_riskcurves_1.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, samples=1000)
ram_results = solve(ram)
println("\nNEUEs = ", neues(ram_results))

for i in 1:2
    push!(eue_params[i], EUECuttingPlaneParams(cem.builds, ram_results, i))
end

cem = ExpansionProblem(sys, repeatedchrono, eue_params, max_eues, optimizer)
write_to_file(cem.model, "model_riskcurves_2.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, samples=1000)
ram_results = solve(ram)
println("\nNEUEs = ", neues(ram_results))

println("\nSingle-region Iterative CEM:")
cem, ram, pcm = iterate_ra_cem(
    sys, repeatedchrono, max_neue, optimizer,
    nsamples=100_000, check_dispatch=true, check_dispatch_voll=voll,
    outfile=timestamp * ".db", unit_commitment=true,
    max_co2_intensity=50., co2_offset_price=100.)

sys_built = SystemParams(cem)
display(sys_built)

println("NEUEs: ", neues(ram))
println()

println("Total Capex: ", value(capex(cem)))
println("\t2030 Capex: ", value(cost_capex(cem.builds, 1)))
println("\t2050 Capex: ", value(cost_capex(cem.builds, 2)))
println("Total Opex: ", value(opex(cem)))
println("\t2030 Variable Opex: ", value(generation_cost(cem.dispatches[1])))
println("\t2030 CO2 Cost: ", value(co2_offset_cost(cem.dispatches[1])))
println("\t2030 Fixed Opex: ", value(cost_fom(cem.builds, 1)))
println("\t2050 Variable Opex: ", value(generation_cost(cem.dispatches[2])))
println("\t2050 CO2 Cost: ", value(co2_offset_cost(cem.dispatches[2])))
println("\t2050 Fixed Opex: ", value(cost_fom(cem.builds, 2)))
println("Total Carbon Offset Cost: ", value(co2_offset_cost(cem)))
println()

println("System Cost: ", value(cost(cem)))
println("System LCOE: ", value(lcoe(cem)))
println("System Emissions Intensity: ", value(emissions_intensity(cem)))

ram = AdequacyProblem(sys_built, samples=100_000)
ram_results = solve(ram)
println("\nNEUEs = ", neues(ram_results))

pcm = DispatchProblem(sys_built, 1, first(repeatedchrono), optimizer,
                      voll=voll, co2_max_intensity=50., co2_offset_price=100.,
                      unit_commitment=true)
solve!(pcm)
println("2030 Operating Cost: ", value(cost(pcm)))
println("2030 Carbon Offset Cost (included in opex): ", value(co2_offset_cost(pcm)))

pcm = DispatchProblem(sys_built, 2, last(repeatedchrono), optimizer,
                      voll=voll, co2_max_intensity=50., co2_offset_price=100.,
                      unit_commitment=true)
solve!(pcm)
println("2050 Operating Cost: ", value(cost(pcm)))
println("2050 Carbon Offset Cost (included in opex): ", value(co2_offset_cost(pcm)))
