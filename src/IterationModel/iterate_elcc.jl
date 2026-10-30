function sweep_iterate_elcc(
    sys::SystemParams, chronology::TimeProxyAssignment,
    elcc_requirements::Vector{Float64}, optimizer; ra_optimizer=nothing,
    elcc_neue_target=1.0, elcc_tol::Float64=.001,
    nsamples::Int=1000, outfile_prefix::String="")

    if isnothing(ra_optimizer)
        ra_optimizer = optimizer
    end

    persist = length(outfile_prefix) > 0

    neue_factor = total_demand(sys) * 1e-6
    elcc_max_eue = elcc_neue_target * neue_factor * powerunits_MW

    ram_base_start = now()
    ram = AdequacyProblem(sys, ra_optimizer, samples=nsamples)
    elcc_base_val, ram_base_result, elcc_ram_result =
        elcc(ram, maximum(sys.demand) * powerunits_MW, elcc_max_eue)
    neue_base_mean, neue_base_stderr = neue_estimate(ram_base_result)
    lole_base_mean, lole_base_stderr = lole_estimate(ram_base_result)
    ram_base_end = now()

    println("ELCC: ", elcc_base_val)
    println("NEUE: ", neue_base_mean, " ± ", neue_base_stderr)
    println("LOLE: ", lole_base_mean, " ± ", lole_base_stderr)

    elcc_planes = ELCCCuttingPlaneParams[]

    for elcc_requirement in elcc_requirements

        println("Expanding with ELCC requirement = ", elcc_requirement)
        println(length(elcc_planes), " ELCC planes already available")

        sys_built = nothing
        cem = nothing
        ram_result = nothing
        elcc_val = elcc_base_val

        elcc_params = ELCCSurfaceParameters(
            elcc_requirement / powerunits_MW, elcc_planes)

        if persist
            req_outfile= "$(outfile_prefix)_$(elcc_requirement).db"
            store_start = now()
            con = DBInterface.connect(DuckDB.DB, req_outfile)
            store(con, sys)
            store_iteration(con, 0)
            store_iteration_step(con, 0, "adequacy", ram_base_start => ram_base_end)
            store(con, 0, ram_base_result)
            store_end = now()
            store_iteration_step(con, 0, "persistence", store_start => store_end)
        end

        n_iters = 0

        while elcc_val < elcc_requirement * (1 - elcc_tol)

            n_iters += 1

            cem_start = now()
            cem = ExpansionProblem(sys, chronology, elcc_params, optimizer)
            solve!(cem)
            cem_end = now()

            ram_start = now()
            sys_built = SystemParams(cem)
            ram = AdequacyProblem(sys_built, ra_optimizer, samples=nsamples)
            elcc_val, ram_result, elcc_ram_result =
                elcc(ram, elcc_params.elcc_min * powerunits_MW, elcc_max_eue)
            neue_mean, neue_stderr = neue_estimate(ram_result)
            lole_mean, lole_stderr = lole_estimate(ram_result)
            ram_end = now()

            println("ELCC: ", elcc_val)
            println("NEUE: ", neue_mean, " ± ", neue_stderr)
            println("LOLE: ", lole_mean, " ± ", lole_stderr)

            aug_start = now()
            push!(elcc_planes, ELCCCuttingPlaneParams(
                cem.builds, elcc_val/powerunits_MW, ram_result))
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
