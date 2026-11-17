@testset "Storage Dispatch" begin

sys = SystemParams("Data/storage_demo")
display(sys)

voll = 9999. # $/MWh

@testset "Full Sequential Chronology" begin

    fullchrono = fullchronologyperiods(sys)

    pcm = DispatchProblem(sys, 1, fullchrono, optimizer, voll=voll)

    @test length(pcm.dispatch.dispatches) == 4
    @test length(pcm.dispatch.recurrences) == 1
    @test length(pcm.dispatch.recurrences[1]) == 4

    solve!(pcm)

    # With perfect round-trip efficiency, charges and discharges should come
    # out to zero overall
    @test sum(
        value(sum(pcm.dispatch.dispatches[i].storagetechs[1].dispatch))
        for i in 1:4) < eps()

    # Variable generation covers load net of storage charging/discharging
    # and unserved energy
    @test value(sum(pcm.dispatch.dispatches[1].variabletechs[1].dispatch)) ≈ 10.4
    @test value(sum(pcm.dispatch.dispatches[2].variabletechs[1].dispatch)) ≈ 10.9
    @test value(sum(pcm.dispatch.dispatches[3].variabletechs[1].dispatch)) ≈ 10.4
    @test value(sum(pcm.dispatch.dispatches[4].variabletechs[1].dispatch)) ≈ 10.8
    
    @test value(cost(pcm.dispatch.dispatches[1].variabletechs[1], 1)) ≈ 104.
    @test value(cost(pcm.dispatch.dispatches[2].variabletechs[1], 1)) ≈ 109.
    @test value(cost(pcm.dispatch.dispatches[3].variabletechs[1], 1)) ≈ 104.
    @test value(cost(pcm.dispatch.dispatches[4].variabletechs[1], 1)) ≈ 108.

    # Given net load levels, only one cost-minimzing SoC trajectory is possible
    @test value(pcm.dispatch.recurrences[1][1].storagetechs[1].soc_last) ≈ .1
    @test value(pcm.dispatch.recurrences[1][2].storagetechs[1].soc_last) ≈ .4
    @test value(pcm.dispatch.recurrences[1][3].storagetechs[1].soc_last) ≈ .7
    @test value(pcm.dispatch.recurrences[1][4].storagetechs[1].soc_last) ≈ .4

    @test value(cost(pcm.dispatch.dispatches[1].storagetechs[1], 1)) ≈ 250.
    @test value(cost(pcm.dispatch.dispatches[2].storagetechs[1], 1)) ≈ 250.
    @test value(cost(pcm.dispatch.dispatches[3].storagetechs[1], 1)) ≈ 270.
    @test value(cost(pcm.dispatch.dispatches[4].storagetechs[1], 1)) ≈ 290.

    @test value(cost(pcm.dispatch.dispatches[1])) ≈ 104. + 250. + 60*voll
    @test value(cost(pcm.dispatch.dispatches[2])) ≈ 109. + 250. + 20*voll
    @test isapprox(value(cost(pcm.dispatch.dispatches[3])), 104. + 270., atol=0.001)
    @test value(cost(pcm.dispatch.dispatches[4])) ≈ 108. + 290. + 40*voll

    @test value(cost(pcm)) ≈
        (104 + 109 + 104 + 108) + (250 + 250 + 270 + 290) + 120 * voll

end

@testset "Dispatch Year 1" begin

    dy1_chrono = fullchronologyperiods(sys, 1)
    pcm = DispatchProblem(sys, 1, dy1_chrono, optimizer, voll=voll)

    @test length(pcm.dispatch.dispatches) == 2
    @test length(pcm.dispatch.recurrences) == 1
    @test length(pcm.dispatch.recurrences[1]) == 2

    solve!(pcm)

    @test sum(
        value(sum(pcm.dispatch.dispatches[i].storagetechs[1].dispatch))
        for i in 1:2) < eps()

    # Variable generation covers load net of storage charging/discharging
    # and unserved energy
    @test value(sum(pcm.dispatch.dispatches[1].variabletechs[1].dispatch)) ≈ 10.4
    @test value(sum(pcm.dispatch.dispatches[2].variabletechs[1].dispatch)) ≈ 10.9
    
    @test value(cost(pcm.dispatch.dispatches[1].variabletechs[1], 1)) ≈ 104.
    @test value(cost(pcm.dispatch.dispatches[2].variabletechs[1], 1)) ≈ 109.

    # Given net load levels, only one cost-minimzing SoC trajectory is possible
    @test value(pcm.dispatch.recurrences[1][1].storagetechs[1].soc_last) ≈ .1
    @test value(pcm.dispatch.recurrences[1][2].storagetechs[1].soc_last) ≈ .4

    @test value(cost(pcm.dispatch.dispatches[1].storagetechs[1], 1)) ≈ 250.
    @test value(cost(pcm.dispatch.dispatches[2].storagetechs[1], 1)) ≈ 250.

    @test value(cost(pcm.dispatch.dispatches[1])) ≈ 104. + 250. + 60*voll
    @test value(cost(pcm.dispatch.dispatches[2])) ≈ 109. + 250. + 20*voll

    @test value(cost(pcm)) ≈
        (104 + 109) + (250 + 250) + 80 * voll

end

@testset "Dispatch Year 2" begin

    dy2_chrono = fullchronologyperiods(sys, 2)
    pcm = DispatchProblem(sys, 1, dy2_chrono, optimizer, voll=voll)

    @test length(pcm.dispatch.dispatches) == 2
    @test length(pcm.dispatch.recurrences) == 1
    @test length(pcm.dispatch.recurrences[1]) == 2

    solve!(pcm)

    # Variable generation covers load net of storage charging/discharging
    # and unserved energy
    @test value(sum(pcm.dispatch.dispatches[1].variabletechs[1].dispatch)) ≈ 10.4
    @test value(sum(pcm.dispatch.dispatches[2].variabletechs[1].dispatch)) ≈ 10.8
    
    @test value(cost(pcm.dispatch.dispatches[1].variabletechs[1], 1)) ≈ 104.
    @test value(cost(pcm.dispatch.dispatches[2].variabletechs[1], 1)) ≈ 108.

    # Given net load levels, only one cost-minimzing SoC trajectory is possible
    @test value(pcm.dispatch.recurrences[1][1].storagetechs[1].soc_last) ≈ .7
    @test value(pcm.dispatch.recurrences[1][2].storagetechs[1].soc_last) ≈ .4

    @test value(cost(pcm.dispatch.dispatches[1].storagetechs[1], 1)) ≈ 270.
    @test value(cost(pcm.dispatch.dispatches[2].storagetechs[1], 1)) ≈ 290.

    @test isapprox(value(cost(pcm.dispatch.dispatches[1])), 104. + 270., atol=0.001)
    @test value(cost(pcm.dispatch.dispatches[2])) ≈ 108. + 290. + 40*voll

    @test value(cost(pcm)) ≈
        (104 + 108) + (270 + 290) + 40 * voll

end

@testset "Probabilistic Adequacy" begin

    n_samples = 10

    ram = AdequacyProblem(sys, optimizer, samples=n_samples)
    ram_results = solve(ram)

    eue_dy1 = 60. + 20.
    lole_dy1 = 3 + 1
    demand_dy1 = 1130 + 1080

    eue_dy2 = 0 + 40.
    lole_dy2 = 0 + 3
    demand_dy2 = 1010 + 1150

    eue = (eue_dy1 + eue_dy2) / 2
    lole = (lole_dy1 + lole_dy2) / 2
    demand = (demand_dy1 + demand_dy2) / 2
    neue = eue / demand * 1_000_000

    # With storage, generation dEUEs are no less than LOLPs
    # Becasuse of hacky dEUE pre-scaling, we need to multiply by the number
    # of dispatch years to recover the true dEUE values
    @test all(2 .* ram_results.generation_dEUEs .>= ram_results.lolps)

    # When all dispatch years are the same length,
    # the sum of the annual EUEs/LOLEs is the sum of the hourly EUEs/LOLPs
    @test lole_dy1 + lole_dy2 ≈ sum(ram_results.lolps)
    @test eue_dy1 + eue_dy2 ≈ sum(ram_results.eues)
    
    eue_mean, eue_stderr = eue_estimate(ram_results, 1)
    @test eue_mean ≈ eue
    @test abs(eue_stderr) < sqrt(eps())

    lole_mean, lole_stderr = lole_estimate(ram_results, 1)
    @test lole_mean ≈ lole
    @test abs(lole_stderr) < sqrt(eps())

    neue_mean, neue_stderr = neue_estimate(ram_results, 1)
    @test neue_mean ≈ neue
    @test abs(neue_stderr) < sqrt(eps())

end

@testset "Pooled Chronologies for Multi-Dispatch-Year Expansion" begin

    null_eues = [EUECuttingPlaneParams[]]
    max_eues = [0.]

    # Custom chronology with Y1 = A -> B, Y2 = C -> A
    chronologies = [DispatchProxyMappings([
        DispatchDay("Day A", 1, sys.times),
        DispatchDay("Day B", 2, sys.times),
        DispatchDay("Day C", 3, sys.times)
    ], [
        DispatchProxyMapping(1:2, [1, 2]),
        DispatchProxyMapping(3:4, [3, 1])
    ])]

    cem = ExpansionProblem(sys, chronologies, null_eues, max_eues, optimizer,
                           cem_voll=voll)
    solve!(cem)

    # With expansion candidates prepended, storage becomes storagetech #2
    # and variable becomes variabletech #3

    @test value(sum(cem.dispatches[1].dispatches[1].storagetechs[2].dispatch)) +
          value(sum(cem.dispatches[1].dispatches[2].storagetechs[2].dispatch)) < eps()

    @test value(sum(cem.dispatches[1].dispatches[3].storagetechs[2].dispatch)) +
          value(sum(cem.dispatches[1].dispatches[1].storagetechs[2].dispatch)) < eps()

    # Variable generation covers load net of storage charging/discharging
    # and unserved energy
    @test value(sum(cem.dispatches[1].dispatches[1].variabletechs[3].dispatch)) ≈ 10.4
    @test value(sum(cem.dispatches[1].dispatches[2].variabletechs[3].dispatch)) ≈ 10.9
    @test value(sum(cem.dispatches[1].dispatches[3].variabletechs[3].dispatch)) ≈ 10.4
    
    @test value(cost(cem.dispatches[1].dispatches[1].variabletechs[3], 1)) ≈ 104.
    @test value(cost(cem.dispatches[1].dispatches[2].variabletechs[3], 1)) ≈ 109.
    @test value(cost(cem.dispatches[1].dispatches[3].variabletechs[3], 1)) ≈ 104.

    @test value(cost(cem.dispatches[1].dispatches[1].storagetechs[2], 1)) ≈ 250.
    @test value(cost(cem.dispatches[1].dispatches[2].storagetechs[2], 1)) ≈ 250.
    @test value(cost(cem.dispatches[1].dispatches[3].storagetechs[2], 1)) ≈ 270.

    cost_a = 104. + 250. + 60*voll
    cost_b = 109. + 250. + 20*voll
    cost_c = 104. + 270. # as a smaller number (no VOLL penalty), more
                         # susceptible to floating point errors outside
                         # relative tolerance (hence atols below)

    @test value(cost(cem.dispatches[1].dispatches[1])) ≈ cost_a
    @test value(cost(cem.dispatches[1].dispatches[2])) ≈ cost_b
    @test value(cost(cem.dispatches[1].dispatches[3])) ≈ cost_c atol=0.001

    @test value(cost(cem.dispatches[1].recurrences[1][1])) ≈ cost_a
    @test value(cost(cem.dispatches[1].recurrences[1][2])) ≈ cost_b
    @test value(cost(cem.dispatches[1].recurrences[2][1])) ≈ cost_c atol=0.001
    @test value(cost(cem.dispatches[1].recurrences[2][2])) ≈ cost_a

    # Given net load levels, only one cost-minimzing SoC trajectory is possible
    @test value(cem.dispatches[1].recurrences[1][1].storagetechs[2].soc_last) ≈ .1 atol=0.001
    @test value(cem.dispatches[1].recurrences[1][2].storagetechs[2].soc_last) ≈ .4
    @test value(cem.dispatches[1].recurrences[2][1].storagetechs[2].soc_last) ≈ .7
    @test value(cem.dispatches[1].recurrences[2][2].storagetechs[2].soc_last) ≈ .4

    total_cost = 2*cost_a + cost_b + cost_c

    @test value(cost(cem.dispatches[1])) ≈ total_cost
    @test value(opex(cem)) ≈ total_cost * 8766/96

end

end
