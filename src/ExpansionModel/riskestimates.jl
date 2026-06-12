### ── EUE Reduction structs (gs/eue_surface_storage cutting-plane approach) ───

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
    riskparams.dEUE_power  * (build.power_new  - riskparams.nameplate_power)  +
    riskparams.dEUE_energy * (build.energy_new - riskparams.nameplate_energy)

struct EUECuttingPlaneRegionParams
    thermaltechs::Vector{ThermalEUEReduction}
    variabletechs::Vector{VariableEUEReduction}
    storagetechs::Vector{StorageEUEReduction}

    # Standard constructor: uses all timesteps from the adequacy result.
    function EUECuttingPlaneRegionParams(
        builds::RegionExpansion, r::Int, adequacy::AdequacyResult)

        stor_dEUEs = adequacy.marginal_eue.storages
        stor_idxs  = adequacy.marginal_eue.region_stor_idxs[r]
        lolps      = adequacy.shortfalls.eventperiod_period_mean

        thermaltechs = [ThermalEUEReduction(build, lolps) for build in builds.thermaltechs]
        variabletechs = [VariableEUEReduction(build, lolps) for build in builds.variabletechs]
        storagetechs = [StorageEUEReduction(build, stor_dEUEs[s])
                        for (s, build) in zip(stor_idxs, builds.storagetechs)]

        return new(thermaltechs, variabletechs, storagetechs)
    end

    # Seasonal constructor: caller provides a pre-filtered lolps vector
    # (non-season timesteps zeroed out) so the dEUE is season-specific.
    function EUECuttingPlaneRegionParams(
        builds::RegionExpansion, r::Int, adequacy::AdequacyResult,
        lolps::Vector{Float64})

        stor_dEUEs = adequacy.marginal_eue.storages
        stor_idxs  = adequacy.marginal_eue.region_stor_idxs[r]

        thermaltechs = [ThermalEUEReduction(build, lolps) for build in builds.thermaltechs]
        variabletechs = [VariableEUEReduction(build, lolps) for build in builds.variabletechs]
        storagetechs = [StorageEUEReduction(build, stor_dEUEs[s])
                        for (s, build) in zip(stor_idxs, builds.storagetechs)]

        return new(thermaltechs, variabletechs, storagetechs)
    end

end

function eue_adjustment(params::EUECuttingPlaneRegionParams, builds::RegionExpansion)

    thermal_adjustments = sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.thermaltechs, builds.thermaltechs);
        init=0)

    variable_adjustments = sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.variabletechs, builds.variabletechs);
        init=0)

    storage_adjustments = sum(eue_adjustment(riskparams, build)
        for (riskparams, build) in zip(params.storagetechs, builds.storagetechs);
        init=0)

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

### ── ReliabilityConstraints ──────────────────────────────────────────────────

struct ReliabilityConstraints

    eue_params::Vector{EUECuttingPlaneParams}

    eue::JuMP.VariableRef
    eue_max::JuMP_LessThanConstraintRef
    eue_cuttingplanes::Vector{JuMP_GreaterThanConstraintRef}

    # Seasonal fields — empty vectors when non-seasonal:
    period_names::Vector{String}
    period_eues::Vector{JuMP.VariableRef}
    period_eue_maxs::Vector{JuMP_LessThanConstraintRef}
    period_cuttingplanes::Vector{JuMP_GreaterThanConstraintRef}

    # ── Non-seasonal constructor (identical to gs/eue_surface_storage) ────────
    function ReliabilityConstraints(
        m::JuMP.Model, builds::SystemExpansion,
        eue_params::Vector{EUECuttingPlaneParams}, eue_max::Float64)

        eue = @variable(m, lower_bound = 0)
        JuMP.set_name(eue, "eue")

        eue_max_con = @constraint(m, eue <= eue_max)
        JuMP.set_name(eue_max_con, "eue_max")

        eue_cuttingplanes = [cuttingplane(m, eue, params, builds)
                             for params in eue_params]

        return new(
            eue_params, eue, eue_max_con, eue_cuttingplanes,
            String[], JuMP.VariableRef[],
            JuMP_LessThanConstraintRef[], JuMP_GreaterThanConstraintRef[])

    end

    # ── Seasonal constructor ──────────────────────────────────────────────────
    # period_eue_params: ordered list of (period_name => cutting_planes) pairs,
    #   one entry per season; order must match the current chronology periods.
    # period_maxes: system-wide EUE upper bound per season (same keys).
    function ReliabilityConstraints(
        m::JuMP.Model, builds::SystemExpansion,
        period_eue_params::Vector{Pair{String,Vector{EUECuttingPlaneParams}}},
        period_maxes::Dict{String,Float64})

        all_params            = EUECuttingPlaneParams[]
        period_names          = String[]
        period_eues           = JuMP.VariableRef[]
        period_eue_maxs       = JuMP_LessThanConstraintRef[]
        period_cuttingplanes  = JuMP_GreaterThanConstraintRef[]

        for (pname, params) in period_eue_params
            haskey(period_maxes, pname) || throw(ArgumentError(
                "Period '$pname' in eue_params has no entry in period_maxes"))

            push!(period_names, pname)

            p_eue = @variable(m, lower_bound = 0)
            JuMP.set_name(p_eue, "eue_$(pname)")
            push!(period_eues, p_eue)

            p_max = @constraint(m, p_eue <= period_maxes[pname])
            JuMP.set_name(p_max, "eue_max_$(pname)")
            push!(period_eue_maxs, p_max)

            for p in params
                push!(all_params, p)
                push!(period_cuttingplanes, cuttingplane(m, p_eue, p, builds))
            end
        end

        # Annual scalar = sum of seasonal scalars (used for reporting / warm-start).
        # The per-season constraints already imply the annual bound.
        annual_max = sum(values(period_maxes))
        eue = @variable(m, lower_bound = 0)
        JuMP.set_name(eue, "eue")
        @constraint(m, eue == sum(period_eues))
        eue_max_con = @constraint(m, eue <= annual_max)
        JuMP.set_name(eue_max_con, "eue_max")

        return new(
            all_params, eue, eue_max_con, JuMP_GreaterThanConstraintRef[],
            period_names, period_eues, period_eue_maxs, period_cuttingplanes)

    end

end

