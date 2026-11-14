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

end
