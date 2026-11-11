@testset "Thermal Dispatch" begin
 
sys = SystemParams("Data/thermal_demo")

fullchrono = fullchronologyperiods(sys)

fuel_cost = 3.69 # $/MMBtu
fuel_co2 = 52.91 * 1e-3 # tonnes/MMBtu (convert from kg/MMBtu in input file)

thermal_capacity = 100 # MW
heat_rate = 6.2 # MMBtu/MWh
startup_heat = 2032.4 # MMBtu/start
thermal_vom = 1.79 # $/MWh
thermal_fom = 31800 * thermal_capacity

variable_capacity = 125 # MW
variable_fom = 29263.7 * variable_capacity

voll = 9999. # $/MWh

demand_day1 = 2150
demand_day2 = 1125

co2_intensity_max = 50. # kg/MWh
co2_offset_price = 100. # $/tonne

@testset "Without Unit Commitment" begin

    pcm = DispatchProblem(sys, 1, fullchrono, optimizer,
                          voll=voll, unit_commitment=false)

    @test demand(pcm.dispatch.dispatches[1]) ≈ demand_day1/powerunits_MW
    @test demand(pcm.dispatch.dispatches[2]) ≈ demand_day2/powerunits_MW

    solve!(pcm)

    # Given the system's load and variable generation (which will be dispatched
    # first), without unit commitment constraints or random outages we would expect
    # the thermal unit to generate 575 MWh on Day 1 and 400 MWh on Day 2, with
    # no unserved energy on Day 1 and 200 MWh unserved on Day 2

    @test sum(value.(pcm.dispatch.dispatches[1].thermaltechs[1].dispatch)) ≈ 5.75
    @test abs(sum(value.(pcm.dispatch.dispatches[1].unserved_energy))) < eps()

    @test sum(value.(pcm.dispatch.dispatches[2].thermaltechs[1].dispatch)) ≈ 4.
    @test sum(value.(pcm.dispatch.dispatches[2].unserved_energy)) ≈ 2.

    generation = 575 + 400 # MWh
    unserved_energy = 200 # MWh

    fuel_burn = generation * heat_rate
    total_co2 = fuel_burn * fuel_co2
    total_cost = fuel_burn * fuel_cost + generation * thermal_vom +
                 unserved_energy * voll 

    @test total_cost ≈ value(cost(pcm))
    @test total_co2 ≈ value(co2(pcm))

    # Apply CO2 intensity cap and offset price for further emissions.
    # Since the thermal unit was already the most expensive, dispatch will not
    # change, just costs

    co2_allowed = co2_intensity_max * 1e-3 * (demand_day1 + demand_day2) # tonnes
    co2_offset = total_co2 - co2_allowed
    co2_offset_cost = co2_offset * co2_offset_price
    total_cost += co2_offset_cost

    pcm = DispatchProblem(sys, 1, fullchrono, optimizer,
                          voll=voll, unit_commitment=false,
                          co2_intensity_max=co2_intensity_max,
                          co2_offset_price=co2_offset_price)

    solve!(pcm)

    @test sum(value.(pcm.dispatch.dispatches[1].thermaltechs[1].dispatch)) ≈ 5.75
    @test abs(sum(value.(pcm.dispatch.dispatches[1].unserved_energy))) < eps()

    @test sum(value.(pcm.dispatch.dispatches[2].thermaltechs[1].dispatch)) ≈ 4.
    @test sum(value.(pcm.dispatch.dispatches[2].unserved_energy)) ≈ 2.

    @test total_cost ≈ value(cost(pcm))
    @test total_co2 ≈ value(co2(pcm))

end


@testset "With Unit Commitment" begin

    pcm = DispatchProblem(sys, 1, fullchrono, optimizer,
                          voll=voll, unit_commitment=true)
    solve!(pcm)
    
    # Given the system's load and variable generation (which will be dispatched
    # first), with unit commitment constraints but no random outages we would
    # expect the thermal unit to generate 900 MWh on Day 1 (1 startup) and
    # 600 MWh on Day 2 (1 startup), with no unserved energy on Day 1 and
    # 200 MWh unserved on Day 2

    @test sum(value.(pcm.dispatch.dispatches[1].thermaltechs[1].dispatch)) ≈ 9.
    @test sum(value.(pcm.dispatch.dispatches[1].thermaltechs[1].units_startup)) ≈ 1.
    @test abs(sum(value.(pcm.dispatch.dispatches[1].unserved_energy))) < eps()

    @test sum(value.(pcm.dispatch.dispatches[2].thermaltechs[1].dispatch)) ≈ 6.
    @test sum(value.(pcm.dispatch.dispatches[2].thermaltechs[1].units_startup)) ≈ 1.
    @test sum(value.(pcm.dispatch.dispatches[2].unserved_energy)) ≈ 2.

    generation = 900 + 600
    unserved_energy = 200
    startups = 2

    fuel_burn = generation * heat_rate + startups * startup_heat
    total_co2 = fuel_burn * fuel_co2
    total_cost = fuel_burn * fuel_cost + generation * thermal_vom +
                 unserved_energy * voll 

    @test total_cost ≈ value(cost(pcm))
    @test total_co2 ≈ value(co2(pcm))

    # Apply CO2 intensity cap and offset price for further emissions.
    # Since the thermal unit was already the most expensive, dispatch will not
    # change, just costs

    co2_allowed = co2_intensity_max * 1e-3 * (demand_day1 + demand_day2) # tonnes
    co2_offset = total_co2 - co2_allowed
    co2_offset_cost = co2_offset * co2_offset_price
    total_cost += co2_offset_cost

    pcm = DispatchProblem(sys, 1, fullchrono, optimizer,
                          voll=voll, unit_commitment=true,
                          co2_intensity_max=co2_intensity_max,
                          co2_offset_price=co2_offset_price)

    solve!(pcm)

    @test sum(value.(pcm.dispatch.dispatches[1].thermaltechs[1].dispatch)) ≈ 9.
    @test sum(value.(pcm.dispatch.dispatches[1].thermaltechs[1].units_startup)) ≈ 1.
    @test abs(sum(value.(pcm.dispatch.dispatches[1].unserved_energy))) < eps()

    @test sum(value.(pcm.dispatch.dispatches[2].thermaltechs[1].dispatch)) ≈ 6.
    @test sum(value.(pcm.dispatch.dispatches[2].thermaltechs[1].units_startup)) ≈ 1.
    @test sum(value.(pcm.dispatch.dispatches[2].unserved_energy)) ≈ 2.

    @test total_cost ≈ value(cost(pcm))
    @test total_co2 ≈ value(co2(pcm))

end

@testset "Probabilistic Adequacy" begin

    n_samples = 1_000

    ram = AdequacyProblem(sys, optimizer, samples=n_samples)
    ram_results = solve(ram)

    # Loss-of-load mean(variance) is 4.5(2.3) on Day 1 and 6(3) on Day 2
    # Unserved energy mean(variance) is 225(7812.5) on Day 1 and 300(9687.5) on Day 2

    lole = 4.5 + 6
    lole_var = 2.3 + 3
    lole_stderr = sqrt(lole_var/n_samples)

    eue = 225 + 300
    eue_var = 7812.5 + 9687.5
    eue_stderr = sqrt(eue_var/n_samples)

    neue = eue / (demand_day1 + demand_day2) * 1_000_000
    neue_stderr = eue_stderr / (demand_day1 + demand_day2) * 1_000_000

    # Absent storage / transmission, generation dEUEs are LOLPs
    @test all(ram_results.generation_dEUEs .≈ ram_results.lolps)

    # When all dispatch years are the same length (or there's only one),
    # LOLE is the sum of LOLPs
    @test first(lole_estimate(ram_results, 1)) ≈ sum(ram_results.lolps)

    lol_mean, lol_stderr = lole_estimate(ram_results, 1)
    @test lol_mean - 2*lol_stderr <= lole <= lol_mean + 2*lol_stderr

    ue_mean, ue_stderr = eue_estimate(ram_results, 1)
    @test ue_mean - 2*ue_stderr <= eue <= ue_mean + 2*ue_stderr

    nue_mean, nue_stderr = neue_estimate(ram_results, 1)
    @test nue_mean - 2*nue_stderr <= neue <= nue_mean + 2*nue_stderr

end

end
