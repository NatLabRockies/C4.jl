struct AdequacyResult

    shortfalls::PRASCore.Results.ShortfallResult
    marginal_eue::MarginalEUEResult
    # TODO: Save transmission EUE gradient data here

end

function show_neues(result::AdequacyResult; regions::Bool=true)

    println("System\t", NEUE(result.shortfalls))

    for region in result.shortfalls.regions.names
        println(region, "\t", NEUE(result.shortfalls, region))
    end

end

neue(result::AdequacyResult) = val(NEUE(result.shortfalls))

region_neues(result::AdequacyResult) =
    [val(NEUE(result.shortfalls, region))
     for region in result.shortfalls.regions.names]

function solve(prob::AdequacyProblem)

    simspec = SequentialMonteCarlo(samples=prob.samples, seed=1, threaded=false)
    sf, dEUE = assess(prob.prassys, simspec, Shortfall(), MarginalEUE())

    return AdequacyResult(sf, dEUE)

end
