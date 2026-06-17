struct VariableSiteExpansion <: DispatchableVariableSite

    params::VariableCandidateSiteParams
    capacity_new::JuMP.VariableRef

    function VariableSiteExpansion(
        m::JuMP.Model, siteparams::VariableCandidateSiteParams,
        techparams::VariableCandidateParams)

        fullname = join([techparams.name, siteparams.name], ",")
        capacity_new = @variable(m, lower_bound=0, upper_bound=siteparams.capacity_max[1])
        JuMP.set_name(capacity_new, "variable_new_capacity[$fullname]")
        new(siteparams, capacity_new)

    end

end

function nameplatecapacity(site::VariableSiteExpansion, i::Int=1)
    i != 1 && error("Only data for the first investment year is available")
    return site.capacity_new
end

availability(site::VariableSiteExpansion, i::Int, d::Int, h::Int) =
    site.params.availability[h, d, i]

VariableExistingSiteParams(build::VariableSiteExpansion) =
    VariableExistingSiteParams(
        build.params.name,
        [value(build.capacity_new)],
        build.params.availability)

VariableCandidateSiteParams(build::VariableSiteExpansion) =
    VariableCandidateSiteParams(
        build.params.name,
        [build.params.capacity_max[1] - value(build.capacity_new)],
        build.params.availability)

function warmstart_builds!(build::VariableSiteExpansion, prev_build::VariableSiteExpansion)
    JuMP.set_start_value(build.capacity_new, value(prev_build.capacity_new))
    return
end


struct VariableExpansion <: DispatchableVariableTech

    params::VariableCandidateParams
    sites::Vector{VariableSiteExpansion}

    function VariableExpansion(
        m::JuMP.Model, techparams::VariableCandidateParams)

        sites = [VariableSiteExpansion(m, siteparams, techparams)
                 for siteparams in techparams.sites]

        new(techparams, sites)

    end

end

sites(tech::VariableExpansion) = tech.sites

cost_generation(tech::VariableExpansion, invyear::Int=1) = tech.params.cost_vom[invyear]

cost(build::VariableExpansion, invyear::Int=1) =
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
