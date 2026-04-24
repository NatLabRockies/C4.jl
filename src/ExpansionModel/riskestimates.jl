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

tail_mean(values::AbstractVector{<:Real}, tail::AbstractVector{Bool}) = begin
    length(values) == length(tail) ||
        error("Tail mask length does not match sample vector length")

    tail_values = values[tail]
    isempty(tail_values) ? 0.0 : sum(tail_values) / length(tail_values)
end

struct ThermalCVaRReduction

    nameplate::Float64
    dCVaR::Float64

    function ThermalCVaRReduction(
        build::ThermalExpansion,
        tail_shortfall_samples::Matrix{Float64},
        tail::AbstractVector{Bool})

        T = size(tail_shortfall_samples, 1)
        nameplate = value(nameplatecapacity(build))
        dCVaR = -sum(
            tail_mean(
                min.(vec(view(tail_shortfall_samples, t, :)), availability(build.params, t)),
                tail)
            for t in 1:T)

        return new(nameplate, dCVaR)

    end

end

cvar_adjustment(riskparams::ThermalCVaRReduction, build::ThermalExpansion) =
    riskparams.dCVaR * (nameplatecapacity(build) - riskparams.nameplate)

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

struct VariableSiteCVaRReduction
    nameplate::Float64
    dCVaR::Float64

    function VariableSiteCVaRReduction(
        build::VariableSiteExpansion,
        tail_shortfall_samples::Matrix{Float64},
        tail::AbstractVector{Bool})

        T = size(tail_shortfall_samples, 1)
        nameplate = value(nameplatecapacity(build))
        dCVaR = -sum(
            tail_mean(
                min.(vec(view(tail_shortfall_samples, t, :)), availability(build, t)),
                tail)
            for t in 1:T)

        return new(nameplate, dCVaR)

    end

end

cvar_adjustment(riskparams::VariableSiteCVaRReduction, build::VariableSiteExpansion) =
    riskparams.dCVaR * (nameplatecapacity(build) - riskparams.nameplate)

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

struct VariableCVaRReduction

    sites::Vector{VariableSiteCVaRReduction}

    function VariableCVaRReduction(
        build::VariableExpansion,
        tail_shortfall_samples::Matrix{Float64},
        tail::AbstractVector{Bool})

        sites = [VariableSiteCVaRReduction(site, tail_shortfall_samples, tail)
                 for site in build.sites]

        return new(sites)

    end

end

cvar_adjustment(riskparams::VariableCVaRReduction, build::VariableExpansion) =
    sum(cvar_adjustment(rp_site, b_site)
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

struct StorageCVaRReduction

    nameplate_power::Float64
    dCVaR_power::Float64

    nameplate_energy::Float64
    dCVaR_energy::Float64

    function StorageCVaRReduction(build::StorageExpansion, stor_dCVaRs::StorMarginalEUE)

        return new(
            value(maxpower(build)),
            stor_dCVaRs.charge + stor_dCVaRs.discharge,
            value(maxenergy(build)),
            stor_dCVaRs.energy
        )

    end

end

cvar_adjustment(riskparams::StorageCVaRReduction, build::StorageExpansion) =
        riskparams.dCVaR_power * (build.power_new - riskparams.nameplate_power) +
        riskparams.dCVaR_energy * (build.energy_new - riskparams.nameplate_energy)

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

struct CVaRCuttingPlaneRegionParams
    thermaltechs::Vector{ThermalCVaRReduction}
    variabletechs::Vector{VariableCVaRReduction}
    storagetechs::Vector{StorageCVaRReduction}

    function CVaRCuttingPlaneRegionParams(
        builds::RegionExpansion,
        r::Int,
        adequacy::AdequacyResult,
        tail_shortfall_samples::Matrix{Float64},
        tail::AbstractVector{Bool},
        stor_dCVaRs::Vector{StorMarginalEUE})

        stor_idxs = adequacy.marginal_eue.region_stor_idxs[r]

        thermaltechs = [ThermalCVaRReduction(build, tail_shortfall_samples, tail)
                        for build in builds.thermaltechs]

        variabletechs = [VariableCVaRReduction(build, tail_shortfall_samples, tail)
                         for build in builds.variabletechs]

        storagetechs = [StorageCVaRReduction(build, stor_dCVaRs[s])
                        for (s, build) in zip(stor_idxs, builds.storagetechs)]

        return new(thermaltechs, variabletechs, storagetechs)

    end

end

function cvar_adjustment(
    params::CVaRCuttingPlaneRegionParams,
    builds::RegionExpansion)

    thermal_adjustments = sum(cvar_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.thermaltechs, builds.thermaltechs);
        init=0
    )

    variable_adjustments = sum(cvar_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.variabletechs, builds.variabletechs);
        init=0
    )

    storage_adjustments = sum(cvar_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.storagetechs, builds.storagetechs);
        init=0
    )

    return thermal_adjustments + variable_adjustments + storage_adjustments

end

struct CVaRCuttingPlaneParams

    base_cvar::Float64
    alpha::Float64
    regions::Vector{CVaRCuttingPlaneRegionParams}

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

function cuttingplane(
    m::JuMP.Model, cvar::JuMP.VariableRef, params::CVaRCuttingPlaneParams,
    builds::SystemExpansion)

    expansion_adjustments = sum(cvar_adjustment(riskparams, builds)
        for (riskparams, builds) in zip(params.regions, builds.regions))

    plane = @constraint(m, cvar >= params.base_cvar + expansion_adjustments)
    JuMP.set_name(plane, "cvar_cutting_plane")

    return plane

end

abstract type AbstractReliabilityConstraints end

struct ReliabilityConstraints <: AbstractReliabilityConstraints

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

struct CVaRReliabilityConstraints <: AbstractReliabilityConstraints

    cvar_params::Vector{CVaRCuttingPlaneParams}

    cvar::JuMP.VariableRef
    cvar_max::JuMP_LessThanConstraintRef
    cvar_cuttingplanes::Vector{JuMP_GreaterThanConstraintRef}

    function CVaRReliabilityConstraints(
        m::JuMP.Model, builds::SystemExpansion,
        cvar_params::Vector{CVaRCuttingPlaneParams}, cvar_max::Float64)

        cvar = @variable(m, lower_bound = 0)
        JuMP.set_name(cvar, "cvar")

        cvar_max = @constraint(m, cvar <= cvar_max)
        JuMP.set_name(cvar_max, "cvar_max")

        cvar_cuttingplanes = [cuttingplane(m, cvar, params, builds)
                              for params in cvar_params]

        new(cvar_params, cvar, cvar_max, cvar_cuttingplanes)

    end

end

nullestimator() = EUECuttingPlaneParams[]
nullcvar_estimator() = CVaRCuttingPlaneParams[]
