struct ThermalELCCIncrease

    nameplate::Float64
    dELCC::Float64

    function ThermalELCCIncrease(
        build::ThermalExpansion, gen_dEUEs::Vector{Float64}, perfect_dEUE::Float64)

        T = length(gen_dEUEs)
        nameplate = value(nameplatecapacity(build))
        dEUE = -sum(gen_dEUEs[t] * availability(build.params, t) for t in 1:T)

        return new(nameplate, dEUE / perfect_dEUE)

    end

end

elcc_adjustment(riskparams::ThermalELCCIncrease, build::ThermalExpansion) =
    riskparams.dELCC * (nameplatecapacity(build) - riskparams.nameplate)

struct VariableSiteELCCIncrease
    nameplate::Float64
    dELCC::Float64

    function VariableSiteELCCIncrease(
        build::VariableSiteExpansion, gen_dEUEs::Vector{Float64}, perfect_dEUE::Float64)

        T = length(gen_dEUEs)
        nameplate = value(nameplatecapacity(build))
        dEUE = -sum(gen_dEUEs[t] * availability(build, t) for t in 1:T)

        return new(nameplate, dEUE / perfect_dEUE)

    end

end

elcc_adjustment(riskparams::VariableSiteELCCIncrease, build::VariableSiteExpansion) =
    riskparams.dELCC * (nameplatecapacity(build) - riskparams.nameplate)

struct VariableELCCIncrease

    sites::Vector{VariableSiteELCCIncrease}

    function VariableELCCIncrease(build::VariableExpansion, gen_dEUEs::Vector{Float64}, perfect_dEUE::Float64)

        sites = [VariableSiteELCCIncrease(site, gen_dEUEs, perfect_dEUE)
                 for site in build.sites]

        return new(sites)

    end

end

elcc_adjustment(riskparams::VariableELCCIncrease, build::VariableExpansion) =
    sum(elcc_adjustment(rp_site, b_site)
        for (rp_site, b_site) in zip(riskparams.sites, build.sites); init=0)

struct StorageELCCIncrease

    nameplate_power::Float64
    dELCC_power::Float64

    function StorageELCCIncrease(
        build::StorageExpansion, power_dEUE::Float64, energy_dEUE::Float64,
        perfect_dEUE::Float64)

        dEUE = power_dEUE + duration(build) * energy_dEUE

        return new(value(maxpower(build)), -dEUE/perfect_dEUE)

    end

end

elcc_adjustment(riskparams::StorageELCCIncrease, build::StorageExpansion) =
        riskparams.dELCC_power * (build.power_new - riskparams.nameplate_power)

struct ELCCCuttingPlaneParams

    base_elcc::Float64

    thermaltechs::Vector{ThermalELCCIncrease}
    variabletechs::Vector{VariableELCCIncrease}
    storagetechs::Vector{StorageELCCIncrease}

    function ELCCCuttingPlaneParams(
        builds::SystemExpansion, base_elcc::Float64, adequacy::AdequacyResult)

        perfect_dEUE = -sum(adequacy.generation_dEUEs)

        thermaltechs = [ThermalELCCIncrease(build, adequacy.generation_dEUEs, perfect_dEUE)
                        for build in builds.thermaltechs]

        variabletechs = [VariableELCCIncrease(build, adequacy.generation_dEUEs, perfect_dEUE)
                        for build in builds.variabletechs]

        storagetechs = [StorageELCCIncrease(build, power_dEUE, energy_dEUE, perfect_dEUE)
                        for (build, power_dEUE, energy_dEUE) in
                            zip(builds.storagetechs,
                                adequacy.storage_power_dEUEs,
                                adequacy.storage_energy_dEUEs)]

        return new(base_elcc, thermaltechs, variabletechs, storagetechs)

    end

end

function cuttingplane(
    m::JuMP.Model, elcc::JuMP.VariableRef, params::ELCCCuttingPlaneParams,
    builds::SystemExpansion)

    elcc_estimate = params.base_elcc

    elcc_estimate += sum(elcc_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.thermaltechs, builds.thermaltechs);
        init=0
    )

    elcc_estimate += sum(elcc_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.variabletechs, builds.variabletechs);
        init=0
    )

    elcc_estimate += sum(elcc_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.storagetechs, builds.storagetechs);
        init=0
    )

    plane = @constraint(m, elcc <= elcc_estimate)
    JuMP.set_name(plane, "elcc_cutting_plane")

    return plane

end

struct ELCCSurfaceConstraints <: AdequacyConstraints

    elcc_params::Vector{ELCCCuttingPlaneParams}

    elcc::JuMP.VariableRef
    elcc_min::JuMP_GreaterThanConstraintRef
    elcc_cuttingplanes::Vector{JuMP_LessThanConstraintRef}

end

mutable struct ELCCSurfaceParameters <: AdequacyParameters
    planes::Vector{ELCCCuttingPlaneParams}
    elcc_min::Float64 # in powerunits_MW

    function ELCCSurfaceParameters(elcc_min::Float64)
        return new(ELCCCuttingPlaneParams[], elcc_min)
    end

end

function adequacy_constraints(
    m::JuMP.Model, builds::SystemExpansion, elcc_params::ELCCSurfaceParameters)

    elcc = @variable(m, lower_bound = 0)
    JuMP.set_name(elcc, "elcc")

    elcc_min = @constraint(m, elcc >= elcc_params.elcc_min)
    JuMP.set_name(elcc_min, "elcc_min")

    elcc_cuttingplanes = [cuttingplane(m, elcc, params, builds)
                         for params in elcc_params.planes]

    return ELCCSurfaceConstraints(
        elcc_params.planes, elcc, elcc_min, elcc_cuttingplanes)

end
