using Statistics

function iterate_elcc(
    sys::SystemParams, base_chronology::TimeProxyAssignment,
    neue_target::Float64, optimizer;
    neue_tol::Float64=.01, elcc_tol::Float64=.001,
    nsamples::Int=1000, skip_existing_stress_periods::Bool=false,
    aspp::Bool=true, endog_risk::Bool=true, outfile::String="",
    check_dispatch::Bool=false, check_dispatch_voll::Float64=NaN,
    ra_optimizer=nothing)

    if isnothing(ra_optimizer)
        ra_optimizer = optimizer
    end

    persist = length(outfile) > 0

    neue_factor = total_demand(sys) * 1e-6
    neue_lb = neue_target * (1 - neue_tol)
    neue_ub = neue_target * (1 + neue_tol)
    
    elcc_max_eue = neue_target * neue_factor * powerunits_MW

    ram_start = now()
    ram = AdequacyProblem(sys, ra_optimizer, samples=nsamples)
    elcc_val, ram_result, elcc_ram_result =
        elcc(ram, maximum(sys.demand) * powerunits_MW, elcc_max_eue)
    ram_end = now()

    println("ELCC: ", elcc_val)
    println("NEUE: ", neue(ram_result))
    println("LOLE: ", sum(ram_result.lolps))

    aug_start = now()

    chronology = if aspp
        add_stressperiod(sys, base_chronology, ram_result,
                         skip_existing=skip_existing_stress_periods)
    else
        base_chronology
    end

    aug_end = now()

    if persist
        store_start = now()
        con = DBInterface.connect(DuckDB.DB, outfile)
        store(con, sys)
        store_iteration(con, 0)
        store_iteration_step(con, 0, "adequacy", ram_start => ram_end)
        store(con, 0, ram_result)
        store_iteration_step(con, 0, "augmentation", aug_start => aug_end)
        store_end = now()
        store_iteration_step(con, 0, "persistence", store_start => store_end)
    end

    sys_built = nothing
    cem = nothing
    prev_cem = nothing
    n_iters = 0

    elcc_prev = 0.
    neue_prev = 1e6
    
    elcc_params = ELCCSurfaceParameters(mean(sys.demand))
    println("Intialized ELCC requirement to ", elcc_params.elcc_min * powerunits_MW)
    elcc_lb = elcc_params.elcc_min * (1 - elcc_tol) * powerunits_MW
    elcc_ub = elcc_params.elcc_min * (1 + elcc_tol) * powerunits_MW

    while true

        while !(elcc_lb <= elcc_val <= elcc_ub)

            n_iters += 1

            elcc_prev = elcc_val
            neue_prev = neue(ram_result)

            cem_start = now()

            cem = ExpansionProblem(sys, chronology, elcc_params, optimizer)
            isnothing(prev_cem) || warmstart_builds!(cem, prev_cem)

            solve!(cem)
            cem_end = now()

            ram_start = now()
            sys_built = SystemParams(cem)
            ram = AdequacyProblem(sys_built, ra_optimizer, samples=nsamples)
            elcc_val, ram_result, elcc_ram_result =
                elcc(ram, elcc_params.elcc_min * powerunits_MW, elcc_max_eue)
            ram_end = now()

            println("ELCC: ", elcc_val)
            println("NEUE: ", neue(ram_result))
            println("LOLE: ", sum(ram_result.lolps))

            aug_start = now()

            if aspp
                chronology = add_stressperiod(
                    sys, chronology, ram_result,
                    skip_existing=skip_existing_stress_periods)
            end

            if endog_risk
                push!(elcc_params.planes,
                      ELCCCuttingPlaneParams(cem.builds, elcc_val/powerunits_MW, elcc_ram_result))
            end

            aug_end = now()

            if persist
                store_start = now()
                store_iteration(con, n_iters)
                store_iteration_step(con, n_iters, "expansion", cem_start => cem_end)
                store_iteration_step(con, n_iters, "adequacy", ram_start => ram_end)
                store_iteration_step(con, n_iters, "augmentation", aug_start => aug_end)
                store(con, n_iters, cem.builds)
                store(con, n_iters, cem.economicdispatch)
                store(con, n_iters, ram_result)
                DBInterface.execute(con, "CHECKPOINT")
                store_end = now()
                store_iteration_step(con, n_iters, "persistence", store_start => store_end)
                DBInterface.execute(con, "CHECKPOINT")
            end

            prev_cem = cem

            neue_lb <= neue(ram_result) <= neue_ub  && break
            aspp || endog_risk || break

        end

        # TODO: Try dynamically updating the ELCC target each iteration?
        neue_val = neue(ram_result)
        neue_lb <= neue_val <= neue_ub  && break

        new_min_elcc = elcc_val -
            (neue_val - neue_target) / (neue_val - neue_prev) * (elcc_val - elcc_prev)

        elcc_params.elcc_min = new_min_elcc / powerunits_MW
        
        elcc_lb = new_min_elcc * (1 - elcc_tol)
        elcc_ub = new_min_elcc * (1 + elcc_tol)
        println("Recalibrated ELCC requirement to $(new_min_elcc)")

    end

    return cem, ram_result

end
