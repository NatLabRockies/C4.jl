function elcc(prob::AdequacyProblem, elcc_initial_guess::Float64, eue_criterion::Float64)

    real_result = solve(prob)

    elcc_prob = deepcopy(prob)

    demand = elcc_initial_guess
    elcc_result = nothing

    while true

        elcc_prob.params.demand .= demand

        elcc_result = solve(elcc_prob)
        eue_mean, eue_stderr = eue_estimate(elcc_result)
        
        if iszero(eue_mean)
            demand *= 1.1
            continue
        end

        eue_diff = eue_mean - eue_criterion

        # Stop when eue estimate within 1 stderr of criterion
        abs(eue_diff) < eue_stderr && break
        
        dEUE_firm = sum(elcc_result.generation_dEUEs)
        demand -= eue_diff / dEUE_firm

    end

    return demand, real_result, elcc_result

end
