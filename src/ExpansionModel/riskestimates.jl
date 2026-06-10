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

struct EUECuttingPlaneRegionParams

    thermaltechs::Vector{ThermalEUEReduction}
    variabletechs::Vector{VariableEUEReduction}
    storagetechs::Vector{StorageEUEReduction}

    function EUECuttingPlaneRegionParams(builds::RegionExpansion, r::Int, adequacy::AdequacyResult)

        thermaltechs = [ThermalEUEReduction(build, adequacy.generation_dEUEs)
                        for build in builds.thermaltechs]

        variabletechs = [VariableEUEReduction(build, adequacy.generation_dEUEs)
                        for build in builds.variabletechs]

        storagetechs = [StorageEUEReduction(build, power_dEUE, energy_dEUE)
                        for (build, power_dEUE, energy_dEUE) in
                            zip(builds.storagetechs,
                                adequacy.storage_power_dEUEs,
                                adequacy.storage_energy_dEUEs)]

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

# CVaR cutting plane types.
# Gradients are computed directly from per-sample per-timestep shortfall data
# in the tail scenarios, following the approach of vl/cvar-stor-eue.

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
        shortfall_samples::Matrix{Float64}, # n_timesteps × n_samples
        tail::AbstractVector{Bool})

        T = size(shortfall_samples, 1)
        nameplate = value(nameplatecapacity(build))
        dCVaR = -sum(
            tail_mean(
                min.(vec(view(shortfall_samples, t, :)), availability(build.params, t)),
                tail)
            for t in 1:T)

        return new(nameplate, dCVaR)

    end

end

cvar_adjustment(riskparams::ThermalCVaRReduction, build::ThermalExpansion) =
    riskparams.dCVaR * (nameplatecapacity(build) - riskparams.nameplate)

struct VariableSiteCVaRReduction

    nameplate::Float64
    dCVaR::Float64

    function VariableSiteCVaRReduction(
        build::VariableSiteExpansion,
        shortfall_samples::Matrix{Float64}, # n_timesteps × n_samples
        tail::AbstractVector{Bool})

        T = size(shortfall_samples, 1)
        nameplate = value(nameplatecapacity(build))
        dCVaR = -sum(
            tail_mean(
                min.(vec(view(shortfall_samples, t, :)), availability(build, t)),
                tail)
            for t in 1:T)

        return new(nameplate, dCVaR)

    end

end

cvar_adjustment(riskparams::VariableSiteCVaRReduction, build::VariableSiteExpansion) =
    riskparams.dCVaR * (nameplatecapacity(build) - riskparams.nameplate)

struct VariableCVaRReduction

    sites::Vector{VariableSiteCVaRReduction}

    function VariableCVaRReduction(
        build::VariableExpansion,
        shortfall_samples::Matrix{Float64},
        tail::AbstractVector{Bool})

        sites = [VariableSiteCVaRReduction(site, shortfall_samples, tail)
                 for site in build.sites]
        return new(sites)

    end

end

cvar_adjustment(riskparams::VariableCVaRReduction, build::VariableExpansion) =
    sum(cvar_adjustment(rp_site, b_site)
        for (rp_site, b_site) in zip(riskparams.sites, build.sites); init=0)

struct StorageCVaRReduction

    nameplate_power::Float64
    dCVaR_power::Float64

    nameplate_energy::Float64
    dCVaR_energy::Float64

    function StorageCVaRReduction(
        build::StorageExpansion,
        power_samples::AbstractVector{Float64}, # n_samples
        energy_samples::AbstractVector{Float64}, # n_samples
        tail::AbstractVector{Bool})

        return new(
            value(maxpower(build)),
            -tail_mean(power_samples, tail),
            value(maxenergy(build)),
            -tail_mean(energy_samples, tail))

    end

end

cvar_adjustment(riskparams::StorageCVaRReduction, build::StorageExpansion) =
        riskparams.dCVaR_power * (build.power_new - riskparams.nameplate_power) +
        riskparams.dCVaR_energy * (build.energy_new - riskparams.nameplate_energy)

struct CVaRCuttingPlaneRegionParams

    thermaltechs::Vector{ThermalCVaRReduction}
    variabletechs::Vector{VariableCVaRReduction}
    storagetechs::Vector{StorageCVaRReduction}

    function CVaRCuttingPlaneRegionParams(
        builds::RegionExpansion,
        shortfall_samples::Matrix{Float64},
        tail::AbstractVector{Bool},
        storage_power_samples::Matrix{Float64}, # n_storages × n_samples
        storage_energy_samples::Matrix{Float64}) # n_storages × n_samples

        thermaltechs = [ThermalCVaRReduction(build, shortfall_samples, tail)
                        for build in builds.thermaltechs]

        variabletechs = [VariableCVaRReduction(build, shortfall_samples, tail)
                        for build in builds.variabletechs]

        storagetechs = [StorageCVaRReduction(build,
                            vec(storage_power_samples[s, :]),
                            vec(storage_energy_samples[s, :]),
                            tail)
                        for (s, build) in enumerate(builds.storagetechs)]

        return new(thermaltechs, variabletechs, storagetechs)

    end

end

function cvar_adjustment(params::CVaRCuttingPlaneRegionParams, builds::RegionExpansion)

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

    base_cvar::Float64  # mean total EUE in MWh across tail samples
    regions::Vector{CVaRCuttingPlaneRegionParams}

end

function cvar_cuttingplane(
    m::JuMP.Model, cvar::JuMP.VariableRef, params::CVaRCuttingPlaneParams,
    builds::SystemExpansion)

    expansion_adjustments = sum(cvar_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.regions, builds.regions))

    plane = @constraint(m, cvar >= params.base_cvar + expansion_adjustments)
    JuMP.set_name(plane, "cvar_cutting_plane")

    return plane

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

        cvar_max_con = @constraint(m, cvar <= cvar_max)
        JuMP.set_name(cvar_max_con, "cvar_max")

        cvar_cuttingplanes = [cvar_cuttingplane(m, cvar, params, builds)
                              for params in cvar_params]

        new(cvar_params, cvar, cvar_max_con, cvar_cuttingplanes)

    end

end
