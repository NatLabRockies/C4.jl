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

optimizer = optimizer_with_attributes(
    HiGHS.Optimizer,
    "log_to_console" => false,
)

sys = SystemParams("Data/toysystem-coppersheet")
n_regions = length(sys.regions)
display(sys)

timestamp = Dates.format(now(), "yyyymmddHHMMSS")

fullchrono = fullchronologyperiods(sys, daylength=2)
repeatedchrono = singleperiod(sys, daylength=2)
null_eue = EUECuttingPlaneParams[]

voll = 9000.

# Note that ExpansionProblem takes its target in terms of
# unnormalized EUE and powerunits_MW!
# Nonzero values need to be scaled appropriately
# Here region.demand is already in powerunits_MW
max_eue = sum(sum(region.demand) for region in sys.regions) / 10_000 # 100 ppm

# For iterate_ra_cem, which takes NEUE
max_neue = 10.

ram = AdequacyProblem(sys, samples=1000)
ram_results = solve(ram)
println("\nBase NEUE = ", neue(ram_results))
println("LOLPs: ", ram_results.lolps)
println("EUEs: ", ram_results.eues)

# Formulate and solve a one-off CEM without risk curves

println("\n\nCopper sheet system, repeated chronology, manual iteration")

cem = ExpansionProblem(sys, repeatedchrono, null_eue, max_eue, optimizer)
write_to_file(cem.model, "model.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, samples=1000)
ram_results = solve(ram) # Dig into these results
println("\nNEUE = ", neue(ram_results))
println("LOLPs: ", ram_results.lolps)
println("EUEs: ", ram_results.eues)

eue_params = [EUECuttingPlaneParams(cem, ram_results)]

cem = ExpansionProblem(sys, repeatedchrono, eue_params, max_eue, optimizer)
write_to_file(cem.model, "model_riskcurves_1.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, samples=1000)
ram_results = solve(ram)
println("\nNEUE = ", neue(ram_results))
println("LOLPs: ", ram_results.lolps)
println("EUEs: ", ram_results.eues)

push!(eue_params, EUECuttingPlaneParams(cem, ram_results))

cem = ExpansionProblem(sys, repeatedchrono, eue_params, max_eue, optimizer)
write_to_file(cem.model, "model_riskcurves_2.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, samples=1000)
ram_results = solve(ram)
println("\nNEUE = ", neue(ram_results))
println("LOLPs: ", ram_results.lolps)
println("EUEs: ", ram_results.eues)

println("\nSingle-region Iterative CEM:")
cem, ram, pcm = iterate_ra_cem(
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

# Disabling multi-region tests until transmission EUE contributions implemented

# # Three-region toy model

# sys = SystemParams("Data/toysystem")
# n_regions = length(sys.regions)
# display(sys)

# # Note that ExpansionProblem takes its target in terms of
# # unnormalized EUE and powerunits_MW!
# # Nonzero values need to be scaled appropriately
# # Here region.demand is already in powerunits_MW
# max_eue = sum(sum(region.demand) for region in sys.regions) / 5000  # 200 ppm

# # For iterate_ra_cem, which takes NEUE
# max_neue = 200.

# ram = AdequacyProblem(sys, samples=1000)
# ram_results = solve(ram)
# println("\nThree-region base reliability:")
# show_neues(ram_results)

# println("\nOne-shot CEM, without risk curves:")
# cem = ExpansionProblem(sys, fullchrono, null_eue, max_eue, optimizer)
# solve!(cem)

# sys_built = SystemParams(cem)
# display(sys_built)

# println("Capex: ", value(capex(cem)))
# println("Opex: ", value(opex(cem)))
# println("System Cost: ", value(cost(cem)))
# println("System LCOE: ", value(lcoe(cem)))

# ram = AdequacyProblem(sys_built, samples=1000)
# ram_results = solve(ram)
# show_neues(ram_results)

# pcm = DispatchProblem(sys_built, ReliabilityDispatch, fullchrono, optimizer)
# solve!(pcm)
# println("Operating Cost (Reliability): ", value(cost(pcm)))

# pcm = DispatchProblem(sys_built, EconomicDispatch, fullchrono, optimizer)
# solve!(pcm)
# println("Operating Cost (Economic): ", value(cost(pcm)))

# # Formulate and solve a one-off CEM with risk curves,
# # based on the outcome of the no-risk-curve build

# println("\nOne-shot CEM, with risk curves:")
# eue_params = [EUECuttingPlaneParams(cem, ram_results)]
# cem = ExpansionProblem(sys, fullchrono, eue_params, max_eue, optimizer)
# write_to_file(cem.model, "model_riskcurves.lp")
# solve!(cem)

# sys_built = SystemParams(cem)
# display(sys_built)

# println("Capex: ", value(capex(cem)))
# println("Opex: ", value(opex(cem)))
# println("System Cost: ", value(cost(cem)))
# println("System LCOE: ", value(lcoe(cem)))

# ram = AdequacyProblem(sys_built, samples=1000)
# ram_results = solve(ram)
# show_neues(ram_results)

# # Formulate and solve an iterative RA-CEM feedback loop

# println("\nIterative CEM:")
# cem, ram, pcm = iterate_ra_cem(
#     sys, fullchrono, max_neue, optimizer,
#     outfile=timestamp * ".db", check_dispatch=true, check_dispatch_voll=voll)

# sys_built = SystemParams(cem)
# display(sys_built)

# println("Capex: ", value(capex(cem)))
# println("Opex: ", value(opex(cem)))
# println("System Cost: ", value(cost(cem)))
# println("System LCOE: ", value(lcoe(cem)))

# ram = AdequacyProblem(sys_built, samples=1000)
# ram_results = solve(ram)
# show_neues(ram_results)

# pcm = DispatchProblem(sys_built, ReliabilityDispatch, fullchrono, optimizer)
# solve!(pcm)
# println("Operating Cost (Reliability): ", value(cost(pcm)))

# pcm = DispatchProblem(sys_built, EconomicDispatch, fullchrono, optimizer, voll)
# solve!(pcm)
# println("Operating Cost (Economic): ", value(cost(pcm)))
