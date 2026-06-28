struct VariableSiteExpansion <: DispatchableVariableSite

    params::VariableCandidateSiteParams
    capacity_new::Vector{JuMP.VariableRef}

    function VariableSiteExpansion(
        m::JuMP.Model, siteparams::VariableCandidateSiteParams,
        techparams::VariableCandidateParams, times::TimeIndices)

        n_invyears = length(times.investment_years)

        capacity_new = @variable(m, [1:n_invyears], lower_bound=0)
        set_upper_bound.(capacity_new, siteparams.capacity_max)

        fullname = join([techparams.name, siteparams.name], ",")
        varnames!(capacity_new, "variable_new_capacity[$fullname]",
                  times.investment_years)

        new(siteparams, capacity_new)

    end

end

function nameplatecapacity(site::VariableSiteExpansion, i::Int)
    return sum(site.capacity_new[1:i])
end

availability(site::VariableSiteExpansion, i::Int, d::Int, h::Int) =
    site.params.availability[h, d, i]

VariableExistingSiteParams(build::VariableSiteExpansion) =
    VariableExistingSiteParams(
        build.params.name,
        cumsum(value.(build.capacity_new)),
        build.params.availability)

VariableCandidateSiteParams(build::VariableSiteExpansion) =
    VariableCandidateSiteParams(
        build.params.name,
        build.params.capacity_max .- value.(build.capacity_new),
        build.params.availability)

function warmstart_builds!(build::VariableSiteExpansion, prev_build::VariableSiteExpansion)
    JuMP.set_start_value.(build.capacity_new, value.(prev_build.capacity_new))
    return
end


struct VariableExpansion <: DispatchableVariableTech

    params::VariableCandidateParams
    sites::Vector{VariableSiteExpansion}

    function VariableExpansion(
        m::JuMP.Model, techparams::VariableCandidateParams, times::TimeIndices)

        sites = [VariableSiteExpansion(m, siteparams, techparams, times)
                 for siteparams in techparams.sites]

        new(techparams, sites)

    end

end

sites(tech::VariableExpansion) = tech.sites

cost_generation(tech::VariableExpansion, invyear::Int) = tech.params.cost_vom[invyear]

cost(build::VariableExpansion, invyear::Int) =
    nameplatecapacity(build, invyear) * build.params.cost_capital[invyear]

VariableExistingParams(build::VariableExpansion) = VariableExistingParams(
    build.params.name,
    build.params.category,
    build.params.cost_vom,
    VariableExistingSiteParams.(build.sites)
)

VariableCandidateParams(build::VariableExpansion) = VariableCandidateParams(
    build.params.name,
    build.params.category,
    build.params.cost_capital,
    build.params.cost_vom,
    VariableCandidateSiteParams.(build.sites)
)
