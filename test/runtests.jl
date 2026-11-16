using Test
using Dates

using C4.Data
using C4.AdequacyModel
using C4.DispatchModel
using C4.ExpansionModel
using C4.IterationModel

import C4: store, powerunits_MW
import C4.ExpansionModel: cost_capex, cost_fom
import C4.DispatchModel: generation_cost, co2_offset_cost,
                         DispatchDay, DispatchProxyMapping, DispatchProxyMappings

using DuckDB

import HiGHS
import JuMP: optimizer_with_attributes, value, termination_status, write_to_file

include("DispatchModel/sequencing.jl")
include("DispatchModel/thermal.jl")

optimizer = optimizer_with_attributes(
    HiGHS.Optimizer,
    "log_to_console" => false,
)

include("thermal_dispatch.jl")
include("storage_dispatch.jl")

sys = SystemParams("Data/toysystem", opex_endyears=10)
display(sys)

timestamp = Dates.format(now(), "yyyymmddHHMMSS")

fullchrono = fullchronologyperiods(sys)
fullchronos = [fullchronologyperiods(sys)
               for i in eachindex(sys.times.investment_years)]
repeatedchrono = [singleperiod(sys, i)
                  for i in eachindex(sys.times.investment_years)]

voll = 9000.

pcm = DispatchProblem(sys, 1, fullchrono, optimizer, voll=voll)
solve!(pcm)

# Note that ExpansionProblem takes its target in terms of
# unnormalized EUE and powerunits_MW!
# Nonzero values need to be scaled appropriately

# Here avg_annual_energy is already in powerunits_MW
max_eues = [
    avg_annual_energy(sys, 1) / 100_000 # 2030 10 ppm
    avg_annual_energy(sys, 2) / 100_000 # 2050 10 ppm
]

eue_params = EUEParameters.(max_eues)
max_neue = 10. # for iterate_neue

ram = AdequacyProblem(sys, optimizer, samples=1000, threaded=false)
ram_results = solve(ram)
println("\nBase NEUEs = ", neue_estimates(ram_results))

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
println("\nNEUEs = ", neue_estimates(ram_results))

for i in 1:2
    push!(eue_params[i].planes, EUECuttingPlaneParams(cem.builds, ram_results, i))
end

cem = ExpansionProblem(sys, repeatedchrono, eue_params, optimizer)
write_to_file(cem.model, "model_riskcurves_1.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, optimizer, samples=1000)
ram_results = solve(ram)
println("\nNEUEs = ", neue_estimates(ram_results))

for i in 1:2
    push!(eue_params[i].planes, EUECuttingPlaneParams(cem.builds, ram_results, i))
end

cem = ExpansionProblem(sys, repeatedchrono, eue_params, optimizer)
write_to_file(cem.model, "model_riskcurves_2.lp")
solve!(cem)

sys_built = SystemParams(cem)
display(sys_built)
println("System Cost: ", value(cost(cem)))

ram = AdequacyProblem(sys_built, optimizer, samples=1000)
ram_results = solve(ram)
println("\nNEUEs = ", neue_estimates(ram_results))

println("\nSingle-region Iterative CEM:")
cem, ram, pcm = iterate_neue(
    sys, fullchronos, max_neue, optimizer,
    nsamples=100_000, check_dispatch_invyears=[1 ,2], check_dispatch_voll=voll,
    outfile=timestamp * "_neue.db", unit_commitment=true,
    co2_intensity_max=[50., 50.], co2_offset_price=100.)

sys_built = SystemParams(cem)
display(sys_built)

println("NEUEs: ", neue_estimates(ram))
println()

println("Total Capex: ", value(capex(cem)))
println("\t2030 Capex: ", value(cost_capex(cem.builds, 1, 0.)))
println("\t2050 Capex: ", value(cost_capex(cem.builds, 2, 0.)))
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

ram = AdequacyProblem(sys_built, optimizer, samples=100_000)
ram_results = solve(ram)
println("\nNEUEs = ", neue_estimates(ram_results))

pcm = DispatchProblem(sys_built, 1, first(repeatedchrono), optimizer,
                      voll=voll, co2_intensity_max=50., co2_offset_price=100.,
                      unit_commitment=true)
solve!(pcm)
println("2030 Operating Cost: ", value(cost(pcm)))
println("2030 Carbon Offset Cost (included in opex): ", value(co2_offset_cost(pcm)))

pcm = DispatchProblem(sys_built, 2, last(repeatedchrono), optimizer,
                      voll=voll, co2_intensity_max=50., co2_offset_price=100.,
                      unit_commitment=true)
solve!(pcm)
println("2050 Operating Cost: ", value(cost(pcm)))
println("2050 Carbon Offset Cost (included in opex): ", value(co2_offset_cost(pcm)))

sweep_iterate_neue(
    sys, fullchronos, [40., 20, 10, 5, 2.5], optimizer,
    nsamples=100_000, outfile_prefix=timestamp * "_neue")
