struct VariableSiteExpansion <: VariableSite

    params::VariableCandidateSiteParams
    capacity_new::JuMP.VariableRef

    function VariableSiteExpansion(
        m::JuMP.Model, siteparams::VariableCandidateSiteParams,
        techparams::VariableCandidateParams)

        fullname = join([techparams.name, siteparams.name], ",")
        capacity_new = @variable(m, lower_bound=0, upper_bound=siteparams.capacity_max)
        JuMP.set_name(capacity_new, "variable_new_capacity[$fullname]")
        new(siteparams, capacity_new)

    end

end

nameplatecapacity(site::VariableSiteExpansion) = site.capacity_new

availability(site::VariableSiteExpansion, t::Int) = site.params.availability[t]

VariableExistingSiteParams(build::VariableSiteExpansion) =
    VariableExistingSiteParams(
        build.params.name,
        value(build.capacity_new),
        build.params.availability)

VariableCandidateSiteParams(build::VariableSiteExpansion) =
    VariableCandidateSiteParams(
        build.params.name,
        build.params.capacity_max - value(build.capacity_new),
        build.params.availability)

function warmstart_builds!(build::VariableSiteExpansion, prev_build::VariableSiteExpansion)
    JuMP.set_start_value(build.capacity_new, value(prev_build.capacity_new))
    return
end


struct VariableExpansion <: VariableTechnology

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

cost_generation(tech::VariableExpansion) = tech.params.cost_generation

cost(build::VariableExpansion) =
    nameplatecapacity(build) * build.params.cost_capital

VariableExistingParams(build::VariableExpansion) = VariableExistingParams(
    build.params.name,
    build.params.category,
    build.params.cost_generation,
    VariableExistingSiteParams.(build.sites)
)

VariableCandidateParams(build::VariableExpansion) = VariableCandidateParams(
    build.params.name,
    build.params.category,
    build.params.cost_capital,
    build.params.cost_generation,
    VariableCandidateSiteParams.(build.sites)
)
