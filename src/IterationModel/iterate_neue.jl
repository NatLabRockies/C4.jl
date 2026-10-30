function sweep_iterate_neue(
    sys::SystemParams, chronology::TimeProxyAssignment,
    neue_requirements::Vector{Float64}, optimizer; neue_tol::Float64=.001,
    nsamples::Int=1000, outfile_prefix::String="",
    ra_optimizer=nothing)

    if isnothing(ra_optimizer)
        ra_optimizer = optimizer
    end

    persist = length(outfile_prefix) > 0

    neue_factor = total_demand(sys) * 1e-6

    ram_start = now()
    ram = AdequacyProblem(sys, ra_optimizer, samples=nsamples)
    ram_base_result = solve(ram)
    neue_base_val, neue_base_stderr = neue_estimate(ram_base_result)
    lole_base_val, lole_base_stderr = lole_estimate(ram_base_result)
    ram_end = now()

    println("NEUE: ", neue_base_val, " ± ", neue_base_stderr)
    println("LOLE: ", lole_base_val, " ± ", lole_base_stderr)

    eue_planes = EUECuttingPlaneParams[]

    for neue_requirement in neue_requirements

        println("Expanding with NEUE requirement = ", neue_requirement)
        println(length(eue_planes), " EUE planes already available")

        sys_built = nothing
        cem = nothing
        ram_result = nothing
        neue_val = neue_base_val

        eue_params = EUEParameters(neue_requirement * neue_factor, eue_planes)

        if persist
            req_outfile = "$(outfile_prefix)_$(neue_requirement).db"
            store_start = now()
            con = DBInterface.connect(DuckDB.DB, req_outfile)
            store(con, sys)
            store_iteration(con, 0)
            store_iteration_step(con, 0, "adequacy", ram_start => ram_end)
            store(con, 0, ram_base_result)
            store_end = now()
            store_iteration_step(con, 0, "persistence", store_start => store_end)
        end

        n_iters = 0

        while neue_val > neue_requirement * (1 + neue_tol)

            n_iters += 1

            cem_start = now()
            cem = ExpansionProblem(sys, chronology, eue_params, optimizer)
            solve!(cem)
            cem_end = now()

            ram_start = now()
            sys_built = SystemParams(cem)
            ram = AdequacyProblem(sys_built, ra_optimizer, samples=nsamples)
            ram_result = solve(ram)
            neue_val, neue_stderr = neue_estimate(ram_result)
            lole_val, lole_stderr = lole_estimate(ram_result)
            ram_end = now()

            println("NEUE: ", neue_val, " ± ", neue_stderr)
            println("LOLE: ", lole_val, " ± ", lole_stderr)

            aug_start = now()
            push!(eue_planes, EUECuttingPlaneParams(cem.builds, ram_result))
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

        end

        display(sys_built)
        println("LOLPs: ", ram_result.lolps)
        println("EUEs: ", ram_result.eues)

        println("Capex: ", value(capex(cem)))
        println("Opex: ", value(opex(cem)))
        println("System Cost: ", value(cost(cem)))
        println("System LCOE: ", value(lcoe(cem)))

    end

end

function iterate_neue(
    sys::SystemParams, base_chronology::TimeProxyAssignment,
    max_neue::Float64, optimizer; neue_tol::Float64=.01,
    nsamples::Int=1000, skip_existing_stress_periods::Bool=false,
    timeout::Float64=Inf, first_feasible::Bool=true,
    aspp::Bool=true, endog_risk::Bool=true, outfile::String="",
    check_dispatch::Bool=false, check_dispatch_voll::Float64=NaN,
    ra_optimizer=nothing)

    if isnothing(ra_optimizer)
        ra_optimizer = optimizer
    end

    persist = length(outfile) > 0
    timeout += time()

    neue_factor = total_demand(sys) * 1e-6
    max_eue = max_neue * neue_factor

    ram_start = now()
    ram = AdequacyProblem(sys, ra_optimizer, samples=nsamples)
    ram_result = solve(ram)
    neue_val, neue_stderr = neue_estimate(ram_result)
    lole_val, lole_stderr = lole_estimate(ram_result)
    ram_end = now()

    println("NEUE: ", neue_val, " ± ", neue_stderr)
    println("LOLE: ", lole_val, " ± ", lole_stderr)

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
    # Shouldn't we use initial RA results here? Right now they're only used for ASPP
    eue_params = EUEParameters(max_eue)
    n_iters = 0

    while (time() < timeout)

        n_iters += 1
        cem_start = now()

        cem = ExpansionProblem(sys, chronology, eue_params, optimizer)
        isnothing(prev_cem) || warmstart_builds!(cem, prev_cem)

        solve!(cem)
        cem_end = now()

        ram_start = now()
        sys_built = SystemParams(cem)
        ram = AdequacyProblem(sys_built, ra_optimizer, samples=nsamples)
        ram_result = solve(ram)
        ram_end = now()

        neue_mean, neue_stderr = neue_estimate(ram_result)
        lole_mean, lole_stderr = lole_estimate(ram_result)

        println("NEUE: ", neue_mean, " ± ", neue_stderr)
        println("LOLE: ", lole_mean, " ± ", lole_stderr)

        is_adequate = neue(ram_result) <= max_neue * (1 + neue_tol)

        aug_start = now()

        if aspp
            chronology = add_stressperiod(
                sys, chronology, ram_result,
                skip_existing=skip_existing_stress_periods)
        end

        if endog_risk
            push!(eue_params.planes, EUECuttingPlaneParams(cem.builds, ram_result))
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

        first_feasible && is_adequate && break

        aspp || endog_risk || break

    end

    pcm = nothing

    if (aspp || endog_risk) && check_dispatch

        pcm_start = now()
        n_iters += 1
        fullchrono = fullchronologyperiods(sys_built, daylength=base_chronology.daylength)
        pcm = DispatchProblem(sys_built, EconomicDispatch, fullchrono,
                              optimizer, check_dispatch_voll)
        solve!(pcm)
        pcm_end = now()

        if persist
            store_iteration(con, n_iters)
            store_iteration_step(con, n_iters, "dispatch", pcm_start => pcm_end)
            store(con, n_iters, pcm.dispatch)
        end

    end

    return cem, ram_result, pcm

end
