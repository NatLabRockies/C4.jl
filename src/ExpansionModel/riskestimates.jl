struct ThermalEUEReduction

    nameplate::Float64
    dEUE::Float64

    function ThermalEUEReduction(
        build::ThermalExpansion, gen_dEUEs::Matrix{Float64}, i::Int)

        n_days = size(gen_dEUEs, 2)
        dEUE = -sum(gen_dEUEs[h, d] * availability(build.params, i, d, h)
                    for h in 1:N_HOURS_IN_DAY, d in 1:n_days)

        nameplate = value(nameplatecapacity(build, i))

        return new(nameplate, dEUE)

    end

end

eue_adjustment(riskparams::ThermalEUEReduction, build::ThermalExpansion, i::Int) =
    riskparams.dEUE * (nameplatecapacity(build, i) - riskparams.nameplate)

struct VariableSiteEUEReduction

    nameplate::Float64
    dEUE::Float64

    function VariableSiteEUEReduction(
        build::VariableSiteExpansion, gen_dEUEs::Matrix{Float64}, i::Int)

        n_days = size(gen_dEUEs, 2)
        dEUE = -sum(gen_dEUEs[h, d] * availability(build, i, d, h)
                    for h in 1:N_HOURS_IN_DAY, d in 1:n_days)

        nameplate = value(nameplatecapacity(build, i))

        return new(nameplate, dEUE)

    end

end

eue_adjustment(
    riskparams::VariableSiteEUEReduction, build::VariableSiteExpansion, i::Int) =
    riskparams.dEUE * (nameplatecapacity(build, i) - riskparams.nameplate)

struct VariableEUEReduction

    sites::Vector{VariableSiteEUEReduction}

    function VariableEUEReduction(
        build::VariableExpansion, gen_dEUEs::Matrix{Float64}, i::Int)

        sites = [VariableSiteEUEReduction(site, gen_dEUEs, i)
                 for site in build.sites]

        return new(sites)

    end

end

eue_adjustment(riskparams::VariableEUEReduction, build::VariableExpansion, i::Int) =
    sum(eue_adjustment(rp_site, b_site, i)
        for (rp_site, b_site) in zip(riskparams.sites, build.sites); init=0)

struct StorageEUEReduction

    nameplate_power::Float64
    dEUE_power::Float64

    nameplate_energy::Float64
    dEUE_energy::Float64

    function StorageEUEReduction(
        build::StorageExpansion, power_dEUE::Float64, energy_dEUE::Float64, i::Int)

        return new(
            value(maxpower(build, i)), -power_dEUE,
            value(maxenergy(build, i)), -energy_dEUE)

    end

end

eue_adjustment(riskparams::StorageEUEReduction, build::StorageExpansion, i::Int) =
        riskparams.dEUE_power * (maxpower(build, i) - riskparams.nameplate_power) +
        riskparams.dEUE_energy * (maxenergy(build, i) - riskparams.nameplate_energy)

struct EUECuttingPlaneParams

    base_eue::Float64

    thermaltechs::Vector{ThermalEUEReduction}
    variabletechs::Vector{VariableEUEReduction}
    storagetechs::Vector{StorageEUEReduction}

    function EUECuttingPlaneParams(
        builds::SystemExpansion, adequacy::AdequacyResult, invyear::Int)

        base_eue = sum(adequacy.eue[invyear]) / powerunits_MW

        # Note these have been pre-divided by the number of dispatch years,
        # so that later summation produces the proper annual average values
        gen_dEUEs = adequacy.generation_dEUEs[:, :, invyear]

        stor_power_dEUEs = adequacy.storage_power_dEUEs[:, invyear]
        stor_energy_dEUEs = adequacy.storage_energy_dEUEs[:, invyear]

        thermaltechs = [
            ThermalEUEReduction(build, gen_dEUEs, invyear)
            for build in builds.thermaltechs]

        variabletechs = [
            VariableEUEReduction(build, gen_dEUEs, invyear)
            for build in builds.variabletechs]

        storagetechs = [
            StorageEUEReduction(build, power_dEUE, energy_dEUE, invyear)
            for (build, power_dEUE, energy_dEUE)
            in zip(builds.storagetechs, stor_power_dEUEs, stor_energy_dEUEs)]

        return new(base_eue, thermaltechs, variabletechs, storagetechs)

    end

end

function eue_estimate(
    params::EUECuttingPlaneParams, builds::SystemExpansion, invyear::Int)

    estimate = params.base_eue

    estimate += sum(eue_adjustment(riskparams, build, invyear)
        for (riskparams, build) in zip(params.thermaltechs, builds.thermaltechs);
        init=0
    )

    estimate += sum(eue_adjustment(riskparams, build, invyear)
        for (riskparams, build) in zip(params.variabletechs, builds.variabletechs);
        init=0
    )

    estimate += sum(eue_adjustment(riskparams, build, invyear)
        for (riskparams, build) in zip(params.storagetechs, builds.storagetechs);
        init=0
    )

    return estimate

end

struct ReliabilityConstraints

    eue_params::Vector{EUECuttingPlaneParams}

    eue::JuMP.VariableRef
    eue_max::JuMP_LessThanConstraintRef

    eue_estimators::Vector{JuMP_ExpressionRef}
    eue_cuttingplanes::Vector{JuMP_GreaterThanConstraintRef}

    function ReliabilityConstraints(
        m::JuMP.Model, builds::SystemExpansion, invyear::Int,
        eue_params::Vector{EUECuttingPlaneParams}, eue_max::Float64)

        n_planes = length(eue_params)

        eue = @variable(m, lower_bound = 0, base_name="eue[$invyear]")
        eue_max = @constraint(m, eue <= eue_max, base_name="eue_max[$invyear]")

        estimators = [eue_estimate(params, builds, invyear) for params in eue_params]

        cuttingplanes = @constraint(m, [p in 1:n_planes],
            eue >= estimators[p], base_name="eue_cuttingplane[$invyear]")

        new(eue_params, eue, eue_max, estimators, cuttingplanes)

    end

end

eue_internal(rc::ReliabilityConstraints) =
    maximum(value(eue_est) for eue_est in rc.eue_estimators; init=0.)
