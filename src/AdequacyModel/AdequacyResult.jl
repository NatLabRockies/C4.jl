struct AdequacyResult

    shortfalls::PRAS.PRASCore.Results.ShortfallResult

end

function show_neues(result::AdequacyResult; regions::Bool=true)

    println("System\t", NEUE(result.shortfalls))

    for region in result.shortfalls.regions.names
        println(region, "\t", NEUE(result.shortfalls, region))
    end

end

region_neues(result::AdequacyResult) =
    [val(NEUE(result.shortfalls, region))
     for region in result.shortfalls.regions.names]

function solve(prob::AdequacyProblem; verbose::Bool=false)

    simspec = SequentialMonteCarlo(samples=prob.samples, seed=1, verbose=verbose)
    sf, = assess(prob.prassys, simspec, Shortfall())

    return AdequacyResult(sf)

end
