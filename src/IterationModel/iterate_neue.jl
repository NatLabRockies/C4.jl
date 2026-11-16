function sweep_iterate_neue(
    sys::SystemParams, chronologies::Vector{DispatchProxyMappings},
    neue_requirements::Vector{Float64}, optimizer; ra_optimizer=nothing,
    neue_tol::Float64=.001, nsamples::Int=1000,
    co2_intensity_max::Vector{Float64}=Float64[], # kg/MWh
    co2_offset_price::Float64=9999., # $/tonne CO2
    unit_commitment::Bool=true, wacc::Float64=0., voll::Float64=9999.,
    outfile_prefix::String="")

    if isnothing(ra_optimizer)
        ra_optimizer = optimizer
    end

    persist = length(outfile_prefix) > 0

    avg_annual_energies = [
        avg_annual_energy(sys, i) for i in eachindex(chronologies)]

    neue_factors = avg_annual_energies .* 1e-6

    ram_start = now()
    ram = AdequacyProblem(sys, ra_optimizer, samples=nsamples)
    ram_base_result = solve(ram)
    neue_base_vals = neues(ram_base_result)
    ram_end = now()

    println("NEUEs: ", neue_base_vals)
    println("LOLEs: ", ram_base_result.lole)

    eue_planes = [EUECuttingPlaneParams[] for _ in eachindex(chronologies)]

    for neue_requirement in neue_requirements

        println("Expanding with NEUE requirement = ", neue_requirement)
        println(length(first(eue_planes)), " EUE planes already available")

        sys_built = nothing
        cem = nothing

        eue_params = EUEParameters.(neue_requirement .* neue_factors, eue_planes)

        if persist
            req_outfile = "$(outfile_prefix)_$(neue_requirement).db"
            store_start = now()
            con = DBInterface.connect(DuckDB.DB, req_outfile)
            store(con, sys, wacc)
            store_iteration(con, 0)
            store_iteration_step(con, 0, "adequacy", ram_start => ram_end)
            store(con, 0, ram_base_result)
            store_end = now()
            store_iteration_step(con, 0, "persistence", store_start => store_end)
        end

        n_iters = 0
        is_adequate = false

        while !is_adequate

            n_iters += 1

            cem_start = now()
            cem = ExpansionProblem(
                sys, chronologies, eue_params, optimizer,
                co2_intensity_max=co2_intensity_max,
                co2_offset_price=co2_offset_price,
                unit_commitment=unit_commitment,
                wacc=wacc, cem_voll=voll)

            solve!(cem)
            cem_end = now()

            ram_start = now()
            sys_built = SystemParams(cem)
            ram = AdequacyProblem(sys_built, ra_optimizer, samples=nsamples)
            ram_result = solve(ram)
            ram_end = now()

            cem_neues = neues_internal(cem)
            println("CEM NEUEs: ", cem_neues)

            ram_neues = neues(ram_result)
            println("RAM NEUEs: ", ram_neues)
            println("RAM LOLEs: ", ram_result.lole)

           any(cem_neues .> ram_neues .* (1 + neue_tol)) &&
               @error("CEM overestimated true EUE - potential EUE surface problem")

            is_adequate = all(ram_neue <= neue_requirement * (1 + neue_tol)
                              for ram_neue in ram_neues)

            aug_start = now()
            for i in eachindex(chronologies)
                push!(eue_planes[i],
                      EUECuttingPlaneParams(cem.builds, ram_result, i))
            end
            aug_end = now()

            if persist

                store_start = now()

                store_iteration(con, n_iters)
                store_iteration_step(con, n_iters, "expansion", cem_start => cem_end)
                store_iteration_step(con, n_iters, "adequacy", ram_start => ram_end)
                store_iteration_step(con, n_iters, "augmentation", aug_start => aug_end)

                store(con, n_iters, cem.builds)

                for (i, dispatch) in enumerate(cem.dispatches)
                    store(con, n_iters, i, dispatch, sys_built.times)
                end

                store(con, n_iters, ram_result)

                DBInterface.execute(con, "CHECKPOINT")

                store_end = now()
                store_iteration_step(con, n_iters, "persistence", store_start => store_end)
                DBInterface.execute(con, "CHECKPOINT")

            end

        end

        display(sys_built)
        println("Capex: ", value(capex(cem)))
        println("Opex: ", value(opex(cem)))
        println("System Cost: ", value(cost(cem)))
        println("System LCOE: ", value(lcoe(cem)))

    end

end

function iterate_neue(
    sys::SystemParams, base_chronologies::Vector{DispatchProxyMappings},
    max_neue::Float64, optimizer; ra_optimizer=nothing,
    neue_tol::Float64=.001,
    nsamples::Int=1000, skip_existing_stress_periods::Bool=false,
    co2_intensity_max::Vector{Float64}=Float64[], # kg/MWh
    co2_offset_price::Float64=9999., # $/tonne CO2
    timeout::Float64=Inf, first_feasible::Bool=true,
    aspp::Bool=true, endog_risk::Bool=true, outfile::String="",
    check_dispatch_invyears::Vector{Int}=Int[], check_dispatch_voll::Real=NaN,
    unit_commitment::Bool=true, wacc::Float64=0.,
    cem_voll::Float64=NaN)

    if isnothing(ra_optimizer)
        ra_optimizer = optimizer
    end

    persist = length(outfile) > 0
    timeout += time()

    avg_annual_energies = [
        avg_annual_energy(sys, i) for i in eachindex(base_chronologies)]
    max_eues = max_neue .* avg_annual_energies .* 1e-6 # in avg annual powerunits_MWh

    ram_start = now()
    ram = AdequacyProblem(sys, ra_optimizer, samples=nsamples)
    ram_result = solve(ram)
    ram_end = now()

    println("NEUEs: ", neues(ram_result))
    println("LOLEs: ", ram_result.lole)

    aug_start = now()

    chronologies = if aspp
        [add_stressperiod(sys, invyear, chrono, ram_result,
                          skip_existing=skip_existing_stress_periods)
         for (invyear, chrono) in enumerate(base_chronologies)]
    else
        base_chronologies
    end

    aug_end = now()

    if persist
        store_start = now()
        con = DBInterface.connect(DuckDB.DB, outfile)
        store(con, sys, wacc)
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
    eue_params = EUEParameters.(max_eues)
    n_iters = 0

    while (time() < timeout)

        n_iters += 1
        cem_start = now()

        cem = ExpansionProblem(sys, chronologies, eue_params, optimizer,
                               co2_intensity_max=co2_intensity_max,
                               co2_offset_price=co2_offset_price,
                               unit_commitment=unit_commitment,
                               wacc=wacc,
                               cem_voll=cem_voll)

        isnothing(prev_cem) || warmstart_builds!(cem, prev_cem)

        # println("Dispatch Recurrences:")
        # for (iy, seq) in enumerate(cem.dispatches)
        #     for (dy, dy_recc) in enumerate(seq.recurrences)
        #         println("InvYear ", iy, ", DispYear ", dy)
        #         for recc in dy_recc
        #             println("\t", recc.repetitions, " x ", recc.dispatch.period.name)
        #         end
        #     end
        # end

        solve!(cem)
        cem_end = now()

        ram_start = now()
        sys_built = SystemParams(cem)
        ram = AdequacyProblem(sys_built, ra_optimizer, samples=nsamples)
        ram_result = solve(ram)
        ram_end = now()

        cem_neues = neues_internal(cem)
        println("CEM NEUEs: ", cem_neues)

        ram_neues = neues(ram_result)
        println("RAM NEUEs: ", ram_neues)
        println("RAM LOLEs: ", ram_result.lole)

       any(cem_neues .> ram_neues .* (1 + neue_tol)) &&
           @error("CEM overestimated true EUE - potential EUE surface problem")

        is_adequate = all(
            neue(ram_result, i) <= max_neue * (1 + neue_tol)
            for i in eachindex(base_chronologies))

        aug_start = now()

        if aspp
            chronologies = [
                add_stressperiod(sys, invyear, chrono, ram_result,
                                 skip_existing=skip_existing_stress_periods)
                 for (invyear, chrono) in enumerate(chronologies)]
        end

        if endog_risk
            for i in eachindex(base_chronologies)
                push!(eue_params[i].planes,
                      EUECuttingPlaneParams(cem.builds, ram_result, i))
            end
        end

        aug_end = now()

        if persist

            store_start = now()

            store_iteration(con, n_iters)
            store_iteration_step(con, n_iters, "expansion", cem_start => cem_end)
            store_iteration_step(con, n_iters, "adequacy", ram_start => ram_end)
            store_iteration_step(con, n_iters, "augmentation", aug_start => aug_end)

            store(con, n_iters, cem.builds)

            for (i, dispatch) in enumerate(cem.dispatches)
                store(con, n_iters, i, dispatch, sys_built.times)
            end

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

    pcms = nothing

    if (aspp || endog_risk) && !isempty(check_dispatch_invyears)

        pcm_start = now()
        n_iters += 1
        persist && store_iteration(con, n_iters)

        for i in check_dispatch_invyears

            co2_limit = length(co2_intensity_max) > 0 ? co2_intensity_max[i] : NaN

            for dy in 1:n_dispatch_years(sys_built.times)

                yearchrono = fullchronologyperiods(sys_built, dy)

                pcm = DispatchProblem(
                    sys_built, i, yearchrono, optimizer;
                    co2_intensity_max=co2_limit,
                    co2_offset_price=co2_offset_price,
                    voll=check_dispatch_voll,
                    unit_commitment=false)

                solve!(pcm)

                if persist
                    store(con, n_iters, pcm.invyear, pcm.dispatch, pcm.system.times)
                    DBInterface.execute(con, "CHECKPOINT")
                end

            end

        end

        pcm_end = now()

        if persist
            store_iteration_step(con, n_iters, "dispatch", pcm_start => pcm_end)
            DBInterface.execute(con, "CHECKPOINT")
        end

    end

    return cem, ram_result, pcms

end
