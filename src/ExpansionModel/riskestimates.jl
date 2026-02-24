struct ThermalEUEReduction

    nameplate::Float64
    dEUE::Float64

    function ThermalEUEReduction(build::ThermalExpansion, lolps::Vector{Float64})

        T = length(lolps)
        nameplate = value(nameplatecapacity(build))
        dEUE = -sum(lolps[t] * availability(build.params, t) for t in 1:T)

        return new(nameplate, dEUE)

    end

end

eue_adjustment(riskparams::ThermalEUEReduction, build::ThermalExpansion) =
    riskparams.dEUE * (nameplatecapacity(build) - riskparams.nameplate)

struct VariableSiteEUEReduction
    nameplate::Float64
    dEUE::Float64

    function VariableSiteEUEReduction(
        build::VariableSiteExpansion, lolps::Vector{Float64})

        T = length(lolps)
        nameplate = value(nameplatecapacity(build))
        dEUE = -sum(lolps[t] * availability(build, t) for t in 1:T)

        return new(nameplate, dEUE)

    end

end

eue_adjustment(riskparams::VariableSiteEUEReduction, build::VariableSiteExpansion) =
    riskparams.dEUE * (nameplatecapacity(build) - riskparams.nameplate)

struct VariableEUEReduction

    sites::Vector{VariableSiteEUEReduction}

    function VariableEUEReduction(build::VariableExpansion, lolps::Vector{Float64})

        sites = [VariableSiteEUEReduction(site, lolps) for site in build.sites]

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

    function StorageEUEReduction(build::StorageExpansion, stor_dEUEs::StorMarginalEUE)

        return new(
            value(maxpower(build)),
            stor_dEUEs.charge + stor_dEUEs.discharge,
            value(maxenergy(build)),
            stor_dEUEs.energy
        )

    end

end

eue_adjustment(riskparams::StorageEUEReduction, build::StorageExpansion) =
        riskparams.dEUE_power * (build.power_new - riskparams.nameplate_power) +
        riskparams.dEUE_energy * (build.energy_new - riskparams.nameplate_energy)

struct EUECuttingPlaneRegionParams
    thermaltechs::Vector{ThermalEUEReduction}
    variabletechs::Vector{VariableEUEReduction}
    storagetechs::Vector{StorageEUEReduction}

    function EUECuttingPlaneRegionParams(builds::RegionExpansion, r::Int, adequacy::AdequacyResult)

        stor_dEUEs = adequacy.marginal_eue.storages

        stor_idxs = adequacy.marginal_eue.region_stor_idxs[r]
        lolps = adequacy.shortfalls.eventperiod_period_mean

        thermaltechs = [ThermalEUEReduction(build, lolps)
                        for build in builds.thermaltechs]

        variabletechs = [VariableEUEReduction(build, lolps)
                        for build in builds.variabletechs]

        storagetechs = [StorageEUEReduction(build, stor_dEUEs[s])
                        for (s, build) in zip(stor_idxs, builds.storagetechs)]

        return new(thermaltechs, variabletechs, storagetechs)

    end

end

function eue_adjustment(params::EUECuttingPlaneRegionParams, builds::RegionExpansion)


    thermal_adjustments = sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.thermaltechs, builds.thermaltechs);
        init=0
    )

    variable_adjustments = sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.variabletechs, builds.variabletechs);
        init=0
    )

    storage_adjustments = sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.storagetechs, builds.storagetechs);
        init=0
    )

    return thermal_adjustments + variable_adjustments + storage_adjustments

end

struct EUECuttingPlaneParams

    base_eue::Float64
    regions::Vector{EUECuttingPlaneRegionParams}
    # TODO: Also collect / use transmission EUE impacts

end

function cuttingplane(
    m::JuMP.Model, eue::JuMP.VariableRef, params::EUECuttingPlaneParams,
    builds::SystemExpansion)

    expansion_adjustments = sum(eue_adjustment(riskparams, builds)
        for (riskparams, builds) in zip(params.regions, builds.regions))

    plane = @constraint(m, eue >= params.base_eue + expansion_adjustments)
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
