const TechnologyExpansion = Union{
    ThermalExpansion,VariableExpansion,StorageExpansion
}
name(tech::TechnologyExpansion) = name(tech.params)

function warmstart_builds!(
    build::T, prev_build::T
) where {T <: TechnologyExpansion}
    warmstart_builds!.(build.sites, prev_build.sites)
    return
end

struct SystemExpansion <: DispatchableSystem

    params::SystemParams

    thermaltechs::Vector{ThermalExpansion}
    variabletechs::Vector{VariableExpansion}
    storagetechs::Vector{StorageExpansion}

    function SystemExpansion(m::JuMP.Model, systemparams::SystemParams)

        thermaltechs = [ThermalExpansion(m, techparams, systemparams.times)
                        for techparams in systemparams.thermaltechs_candidate]

        variabletechs = [VariableExpansion(m, techparams, systemparams.times)
                        for techparams in systemparams.variabletechs_candidate]

        storagetechs = [StorageExpansion(m, techparams, systemparams.times)
                        for techparams in systemparams.storagetechs_candidate]

        new(systemparams, thermaltechs, variabletechs, storagetechs)

    end

end

name(system::SystemExpansion) = system.params.name

demand(system::SystemExpansion, i::Int, d::Int, h::Int) =
    demand(system.params, i, d, h)

# Annualized costs in i-th investment period include annualized costs resulting
# from all earlier investments
cost(build::SystemExpansion, invyear::Int) = sum(
    sum(cost(thermaltech, i) for thermaltech in build.thermaltechs; init=0) +
    sum(cost(variabletech, i) for variabletech in build.variabletechs; init=0) +
    sum(cost(storagetech, i) for storagetech in build.storagetechs; init=0)
for i in 1:invyear)

thermaltechs(system::SystemExpansion) =
    [system.thermaltechs; system.params.thermaltechs_existing]

variabletechs(system::SystemExpansion) =
    [system.variabletechs; system.params.variabletechs_existing]

storagetechs(system::SystemExpansion) =
    [system.storagetechs; system.params.storagetechs_existing]
