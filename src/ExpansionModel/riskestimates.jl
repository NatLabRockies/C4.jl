struct ThermalEUEReduction

    nameplate::Float64
    dEUE::Float64

    function ThermalEUEReduction(build::ThermalExpansion, gen_dEUEs::Vector{Float64})

        T = length(gen_dEUEs)
        nameplate = value(nameplatecapacity(build))
        dEUE = -sum(gen_dEUEs[t] * availability(build.params, t) for t in 1:T)

        return new(nameplate, dEUE)

    end

end

eue_adjustment(riskparams::ThermalEUEReduction, build::ThermalExpansion) =
    riskparams.dEUE * (nameplatecapacity(build) - riskparams.nameplate)

struct VariableSiteEUEReduction
    nameplate::Float64
    dEUE::Float64

    function VariableSiteEUEReduction(
        build::VariableSiteExpansion, gen_dEUEs::Vector{Float64})

        T = length(gen_dEUEs)
        nameplate = value(nameplatecapacity(build))
        dEUE = -sum(gen_dEUEs[t] * availability(build, t) for t in 1:T)

        return new(nameplate, dEUE)

    end

end

eue_adjustment(riskparams::VariableSiteEUEReduction, build::VariableSiteExpansion) =
    riskparams.dEUE * (nameplatecapacity(build) - riskparams.nameplate)

struct VariableEUEReduction

    sites::Vector{VariableSiteEUEReduction}

    function VariableEUEReduction(build::VariableExpansion, gen_dEUEs::Vector{Float64})

        sites = [VariableSiteEUEReduction(site, gen_dEUEs) for site in build.sites]

        return new(sites)

    end

end

eue_adjustment(riskparams::VariableEUEReduction, build::VariableExpansion) =
    sum(eue_adjustment(rp_site, b_site)
        for (rp_site, b_site) in zip(riskparams.sites, build.sites); init=0)

struct StorageEUEReduction

    nameplate_power::Float64
    dEUE_power::Float64

    nameplate_energy::Float64
    dEUE_energy::Float64

    function StorageEUEReduction(
        build::StorageExpansion, power_dEUE::Float64, energy_dEUE::Float64)

        return new(
            value(maxpower(build)), -power_dEUE,
            value(maxenergy(build)), -energy_dEUE)

    end

end

eue_adjustment(riskparams::StorageEUEReduction, build::StorageExpansion) =
        riskparams.dEUE_power * (build.power_new - riskparams.nameplate_power) +
        riskparams.dEUE_energy * (build.energy_new - riskparams.nameplate_energy)

struct EUECuttingPlaneParams

    base_eue::Float64

    thermaltechs::Vector{ThermalEUEReduction}
    variabletechs::Vector{VariableEUEReduction}
    storagetechs::Vector{StorageEUEReduction}

    function EUECuttingPlaneParams(builds::SystemExpansion, adequacy::AdequacyResult)

        base_eue = sum(adequacy.eues) / powerunits_MW

        thermaltechs = [ThermalEUEReduction(build, adequacy.generation_dEUEs)
                        for build in builds.thermaltechs]

        variabletechs = [VariableEUEReduction(build, adequacy.generation_dEUEs)
                        for build in builds.variabletechs]

        storagetechs = [StorageEUEReduction(build, power_dEUE, energy_dEUE)
                        for (build, power_dEUE, energy_dEUE) in
                            zip(builds.storagetechs,
                                adequacy.storage_power_dEUEs,
                                adequacy.storage_energy_dEUEs)]

        return new(base_eue, thermaltechs, variabletechs, storagetechs)

    end

end

function cuttingplane(
    m::JuMP.Model, eue::JuMP.VariableRef, params::EUECuttingPlaneParams,
    builds::SystemExpansion)

    eue_estimate = params.base_eue

    eue_estimate += sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.thermaltechs, builds.thermaltechs);
        init=0
    )

    eue_estimate += sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.variabletechs, builds.variabletechs);
        init=0
    )

    eue_estimate += sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.storagetechs, builds.storagetechs);
        init=0
    )

    plane = @constraint(m, eue >= eue_estimate)
    JuMP.set_name(plane, "eue_cutting_plane")

    return plane

end

struct ReliabilityConstraints

    eue_params::Vector{EUECuttingPlaneParams}

    eue::JuMP.VariableRef
    eue_max::JuMP_LessThanConstraintRef
    eue_cuttingplanes::Vector{JuMP_GreaterThanConstraintRef}

    function ReliabilityConstraints(
        m::JuMP.Model, builds::SystemExpansion,
        eue_params::Vector{EUECuttingPlaneParams}, eue_max::Float64)

        eue = @variable(m, lower_bound = 0)
        JuMP.set_name(eue, "eue")

        eue_max = @constraint(m, eue <= eue_max)
        JuMP.set_name(eue_max, "eue_max")

        eue_cuttingplanes = [cuttingplane(m, eue, params, builds)
                             for params in eue_params]

        new(eue_params, eue, eue_max, eue_cuttingplanes)

    end

end
