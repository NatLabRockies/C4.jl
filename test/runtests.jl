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

optimizer = optimizer_with_attributes(
    HiGHS.Optimizer,
    "log_to_console" => false,
)

sys = SystemParams("Data/toysystem")
display(sys)

timestamp = Dates.format(now(), "yyyymmddHHMMSS")

fullchrono = fullchronologyperiods(sys, daylength=2)
repeatedchrono = singleperiod(sys, daylength=2)

voll = 9000.

pcm = DispatchProblem(sys, fullchrono, optimizer, voll=voll)
solve!(pcm)

# Note that ExpansionProblem takes its target in terms of
# unnormalized EUE and powerunits_MW!
# Nonzero values need to be scaled appropriately
# Here region.demand is already in powerunits_MW
max_eue = total_demand(sys) / 100_000 # 10 ppm
max_neue = 10. # for iterate_neue

eue_params = EUEParameters(max_eue)

ram = AdequacyProblem(sys, optimizer, samples=1000)
ram_results = solve(ram)
println("\nBase NEUE = ", neue(ram_results))
println("LOLPs: ", ram_results.lolps)
println("EUEs: ", ram_results.eues)

# Formulate and solve a one-off CEM without risk curves

println("\n\nCopper sheet system, repeated chronology, manual iteration")

cem = ExpansionProblem(sys, repeatedchrono, eue_params, optimizer)
write_to_file(cem.model, "model.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, optimizer, samples=1000)
ram_results = solve(ram) # Dig into these results
println("\nNEUE = ", neue(ram_results))
println("LOLPs: ", ram_results.lolps)
println("EUEs: ", ram_results.eues)

push!(eue_params.planes, EUECuttingPlaneParams(cem.builds, ram_results))

cem = ExpansionProblem(sys, repeatedchrono, eue_params, optimizer)
write_to_file(cem.model, "model_riskcurves_1.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, optimizer, samples=1000)
ram_results = solve(ram)
println("\nNEUE = ", neue(ram_results))
println("LOLPs: ", ram_results.lolps)
println("EUEs: ", ram_results.eues)

push!(eue_params.planes, EUECuttingPlaneParams(cem.builds, ram_results))

cem = ExpansionProblem(sys, repeatedchrono, eue_params, optimizer)
write_to_file(cem.model, "model_riskcurves_2.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, optimizer, samples=1000)
ram_results = solve(ram)
println("\nNEUE = ", neue(ram_results))
println("LOLPs: ", ram_results.lolps)
println("EUEs: ", ram_results.eues)

println("\nSingle-region Iterative CEM:")
cem, ram, pcm = iterate_neue(
    sys, repeatedchrono, max_neue, optimizer,
    nsamples=100_000, check_dispatch=false, check_dispatch_voll=voll,
    outfile=timestamp * ".db")

sys_built = SystemParams(cem)
display(sys_built)
println("LOLPs: ", ram.lolps)
println("EUEs: ", ram.eues)

println("Capex: ", value(capex(cem)))
println("Opex: ", value(opex(cem)))
println("System Cost: ", value(cost(cem)))
println("System LCOE: ", value(lcoe(cem)))
