struct AdequacyResult

    shortfalls::PRAS.PRASCore.Results.ShortfallResult
    shortfallsamples::PRAS.PRASCore.Results.ShortfallSamplesResult

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

function solve(prob::AdequacyProblem)

    simspec = SequentialMonteCarlo(samples=prob.samples, seed=1)
    sf, sfs = assess(prob.prassys, simspec, Shortfall(), ShortfallSamples())

    return AdequacyResult(sf, sfs)

end
