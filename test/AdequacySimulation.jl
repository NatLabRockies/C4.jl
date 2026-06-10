@testset "AdequacySimulation" begin

import C4.AdequacyModel: AdequacyParams, StorageParams,
                         DispatchState, ResultAccumulator, AdequacySimulationResult,
                         shift_energy_forward!, drawdown_soc!, solve_single!

@testset "Deterministic single-storage" begin

    stor1 = StorageParams(9//10, 9//10, 5, 10)

    prob = AdequacyParams(
        [10//1, 12//1],
        fill(11//1, 1, 2),
        zeros(2, 1),
        ones(2, 1),
        [stor1]
    )

    @testset "Manual advance" begin

        state = DispatchState(prob)
        
        state.imbalance .= [1., -1.]
        state.storage_soc .= 0.
        state.storage_dispatch .= 0.

        shift_energy_forward!(state, prob, 1)

        @test state.imbalance == [0, -19//100]
        @test state.storage_soc == [9//10]
        @test state.storage_dispatch == [-1; 81//100;;]

        drawdown_soc!(state, prob, 2)

        @test state.imbalance == [0, -19//100]
        @test state.storage_soc == [0]
        @test state.storage_dispatch == [-1; 81//100;;]

    end

    @testset "Automatic advance" begin

        state = DispatchState(prob)
        resacc = ResultAccumulator(prob)
        solve_single!(state, resacc, prob, 0)
        results = AdequacySimulationResult(prob, resacc)
        
        # Test results
        @test resacc.n_samples == 1
        @test results.lolps ≈ [0., 1.]
        @test results.eues ≈ [0., .19]
        @test results.generation_dEUEs ≈ [.81, 1]
        @test results.storage_power_dEUEs ≈ [0; 0]
        @test results.storage_energy_dEUEs ≈ [0; 0]

    end
    
    @testset "Multiple samples" begin

        results = solve(prob, samples=10, threaded=false)
        
        @test results.lolps ≈ [0., 1.]
        @test results.eues ≈ [0., .19]
        @test results.generation_dEUEs ≈ [.81, 1]

    end

end

@testset "Deterministic multi-storage" begin

    stor1 = StorageParams(9//10, 9//10, 1, 9//10)
    stor2 = StorageParams(8//10, 8//10, 1, 8//10)

    prob = AdequacyParams(
        [10//1, 10//1, 13//1],
        fill(11//1, 1, 3),
        zeros(3, 1),
        ones(3, 1),
        [stor1, stor2]
    )

    @testset "Manual advance" begin

        state = DispatchState(prob)
        
        state.imbalance .= [1, 1, -2]
        state.storage_soc .= 0
        state.storage_dispatch .= 0

        shift_energy_forward!(state, prob, 1)

        @test state.imbalance == [0, 1, -119//100]
        @test state.storage_soc == [9//10, 0]
        @test state.storage_dispatch == [-1 0; 0 0; 81//100 0]
        
        shift_energy_forward!(state, prob, 2)

        @test state.imbalance == [0, 0, -55//100]
        @test state.storage_soc == [9//10, 8//10]
        @test state.storage_dispatch == [-1 0; 0 -1; 81//100 64//100]

        drawdown_soc!(state, prob, 3)

        @test state.imbalance == [0, 0, -55//100]
        @test state.storage_soc == [0, 0]
        @test state.storage_dispatch == [-1 0; 0 -1; 81//100 64//100]

    end

    @testset "Automatic advance" begin

        state = DispatchState(prob)
        resacc = ResultAccumulator(prob)
        solve_single!(state, resacc, prob, 0)
        results = AdequacySimulationResult(prob, resacc)

        @test resacc.n_samples == 1
        @test results.lolps ≈ [0, 0, 1.]
        @test results.eues ≈ [0, 0, .55]
        @test results.generation_dEUEs ≈ [0., 0, 1]
        @test results.storage_power_dEUEs ≈ [0 0; 0 0; 0 0]
        @test results.storage_energy_dEUEs ≈ [0 0; .9 .8; 0 0]

    end
    
    @testset "Multiple samples" begin

        results = solve(prob, samples=10)

        @test results.lolps ≈ [0, 0, 1.]
        @test results.eues ≈ [0, 0, .55]
        @test results.generation_dEUEs ≈ [0., 0, 1]
        @test results.storage_power_dEUEs ≈ [0 0; 0 0; 0 0]
        @test results.storage_energy_dEUEs ≈ [0 0; .9 .8; 0 0]

    end

end

rand_pct(x::Int=100) = rand(1:x)//100

@testset "Fuzzed Multi-Storage" begin

    @testset "Previously Problematic Problems" begin

        prob = AdequacyParams(
            [-11//5, 9//4],
            Matrix{Rational{Int64}}(undef, 0, 2),
            Matrix{Float64}(undef, 2, 0),
            Matrix{Float64}(undef, 2, 0),
            [StorageParams(1//1, 1//1, 41//50, 197//100),
             StorageParams(1//1, 1//1, 36//25, 73//50)])

        state = DispatchState(prob)
        resacc = ResultAccumulator(prob)
        solve_single!(state, resacc, prob, 0)
        results = AdequacySimulationResult(prob, resacc)

        @test results.lolps ≈ [0, 1.]
        @test results.eues ≈ [0, _]
        @test results.generation_dEUEs ≈ [27/1250, 1]
        @test results.storage_power_dEUEs ≈ [0 0; 0 0]
        # @test results.storage_energy_dEUEs ≈ [0 0; .9 .8;]

        prob = AdequacyParams(
            [-21//100, 217//100],
            Matrix{Rational{Int64}}(undef, 0, 2),
            Matrix{Float64}(undef, 2, 0),
            Matrix{Float64}(undef, 2, 0),
            [StorageParams(27//50, 49//100, 2//5, 7//100),
             StorageParams(3//50, 9//25, 73//100, 67//100)]
        )

        state = DispatchState(prob)
        resacc = ResultAccumulator(prob)
        solve_single!(state, resacc, prob, 0)
        results = AdequacySimulationResult(prob, resacc)

        @test results.lolps ≈ [0, 1.]
        @test results.eues ≈ [0, 533491/250000]
        @test results.generation_dEUEs ≈ [27/1250, 1]
        @test results.storage_power_dEUEs ≈ [0 0; 0 0]
        # @test results.storage_energy_dEUEs ≈ [0 0; .9 .8;]

    end

    N = 1000
    T = 2
    S = 2

    for _ in 1:N

        demand = [rand(-300:300)//100 for _ in 1:T]

        stors = [
            #StorageParams(rand_pct(), rand_pct(), rand_pct(150), rand_pct(300))
            StorageParams(1, 1, rand_pct(150), rand_pct(300))
            for _ in 1:S]
        sort!(stors, by = s -> s.charge_eff * s.discharge_eff, rev=true)

        prob = AdequacyParams(
            demand, fill(0//1, 0, T), zeros(T, 0), ones(T, 0), stors)

        state = DispatchState(prob)
        resacc = ResultAccumulator(prob)
        solve_single!(state, resacc, prob, 0)

    end

end

@testset "Probabilistic outages" begin

    @testset "Steady state, no storage" begin

        prob = AdequacyParams(
            [10//1, 12//1],
            fill(6//1, 2, 2),
            fill(0.1, 2, 2),
            fill(0.9, 2, 2),
            StorageParams[]
        )
        
        results = solve(prob, samples=100)
        
        # @test results.lolps ≈ [.19, .19]
        # @test results.eues ≈ [.82, 1.2]

    end

end
end
