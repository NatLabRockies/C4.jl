@testset "AdequacySimulation" begin

import C4.AdequacyModel: AdequacyParams, GeneratorParams, StorageParams,
                         DispatchState, ResultAccumulator, AdequacySimulationResult,
                         shift_energy_forward!, drawdown_soc!, solve_single!

@testset "Deterministic single-storage" begin

    gen1 = GeneratorParams(11., 0.0, 1.0)
    stor1 = StorageParams(0.9, 0.9, 5., 10.)

    prob = AdequacyParams(
        [10., 12.],
        [gen1 gen1],
        [stor1]
    )

    @testset "Manual advance" begin

        state = DispatchState(prob)
        
        state.imbalance .= [1., -1.]
        state.storage_soc .= 0.
        state.storage_dispatch .= 0.

        shift_energy_forward!(state, prob, 1)

        @test state.imbalance ≈ [0., -0.19]
        @test state.storage_soc ≈ [0.9]
        @test state.storage_dispatch ≈ [-1.; 0.81]

        drawdown_soc!(state, prob, 2)

        @test state.imbalance ≈ [0., -0.19]
        @test state.storage_soc ≈ [0.0]
        @test state.storage_dispatch ≈ [-1.; 0.81]

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

        results = solve(prob, samples=10)
        
        @test results.lolps ≈ [0., 1.]
        @test results.eues ≈ [0., .19]
        @test results.generation_dEUEs ≈ [.81, 1]

    end

end

@testset "Deterministic multi-storage" begin

    gen1 = GeneratorParams(11., 0.0, 1.0)
    stor1 = StorageParams(0.9, 0.9, 1., .9)
    stor2 = StorageParams(0.8, 0.8, 1., .8)

    prob = AdequacyParams(
        [10., 10, 13.],
        [gen1 gen1 gen1],
        [stor1, stor2]
    )

    @testset "Manual advance" begin

        state = DispatchState(prob)
        
        state.imbalance .= [1., 1., -2.]
        state.storage_soc .= 0.
        state.storage_dispatch .= 0.

        shift_energy_forward!(state, prob, 1)

        @test state.imbalance ≈ [0, 1, -1.19]
        @test state.storage_soc ≈ [.9, 0]
        @test state.storage_dispatch ≈ [-1 0; 0 0; .81 0]
        
        shift_energy_forward!(state, prob, 2)

        @test state.imbalance ≈ [0, 0, -.55]
        @test state.storage_soc ≈ [.9, .8]
        @test state.storage_dispatch ≈ [-1 0; 0 -1; .81 .64]

        drawdown_soc!(state, prob, 3)

        @test state.imbalance ≈ [0, 0, -.55]
        #@test state.storage_soc ≈ [0., 0] # Passes, but compare-to-zero issues
        @test state.storage_dispatch ≈ [-1 0; 0 -1; .81 .64]

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
        # TODO: Derive formal primal/dual objectives & show these
        #       results satisfy complementarity slackness

    end
    
    @testset "Multiple samples" begin

        results = solve(prob, samples=10)
        
        @test results.lolps ≈ [0, 0, 1.]
        @test results.eues ≈ [0, 0, .55]
        @test results.generation_dEUEs ≈ [0., 0, 1]

    end

end

@testset "Probabilistic outages" begin

    @testset "Steady state, no storage" begin

        gen = GeneratorParams(6., 0.1, 0.9)

        prob = AdequacyParams(
            [10., 12.],
            [gen gen; gen gen],
            StorageParams[]
        )
        
        results = solve(prob, samples=100)
        
        # @test results.lolps ≈ [.19, .19]
        # @test results.eues ≈ [.82, 1.2]

    end

end
end
