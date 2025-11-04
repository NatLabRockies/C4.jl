function SystemParams(datadir::String)

    system = load_system(datadir)

    thermaldir = joinpath(datadir, "thermal")

    load_fuels!(system, thermaldir)
    load_existing_thermaltechs!(system, thermaldir)
    load_existing_thermalsites!(system, thermaldir)

    load_candidate_thermaltechs!(system, thermaldir)

    variabledir = joinpath(datadir, "variable")

    load_existing_variabletechs!(system, variabledir)
    load_existing_variablesites!(system, variabledir)

    load_candidate_variabletechs!(system, variabledir)
    load_candidate_variablesites!(system, variabledir)

    storagedir = joinpath(datadir, "storage")

    load_existing_storagetechs!(system, storagedir)
    load_existing_storagesites!(system, storagedir)

    load_candidate_storagetechs!(system, storagedir)

    return system

end

function load_system(datadir::String)

    name = basename(datadir)

    demandpath = joinpath(datadir, "demand.csv")
    data = readdlm(demandpath, ',')

    timestamps_raw = DateTime.(data[:, 1], dateformat"y-m-dTH:M:S.s")
    timestamps = first(timestamps_raw):Hour(1):last(timestamps_raw)

    timestamps == timestamps_raw || error("Input timesteps should be hourly")

    demand = Float64.(data[:, 2]) / powerunits_MW

    return SystemParams(
        name, timestamps, demand,
        FuelParams[],
        ThermalExistingParams[],
        ThermalCandidateParams[],
        VariableExistingParams[],
        VariableCandidateParams[],
        StorageExistingParams[],
        StorageCandidateParams[])

end

function load_fuels!(system::SystemParams, datadir::String)

    fuelspath = joinpath(datadir, "fuels.csv")

    data = readdlm(fuelspath, ',')

    validate_columns(data, ["fuel", "cost", "co2_factor"], fuelspath)
    allunique(data[:,1]) || error("Duplicate fuel names in $fuelspath")

    for f in 2:size(data, 1)

        fuelname = string(data[f, 1])
        cost = Float64(data[f, 2])
        co2_factor = Float64(data[f, 3])

        fuel = FuelParams(fuelname, cost, co2_factor)
        push!(system.fuels, fuel)

    end

end

function load_existing_thermaltechs!(system::SystemParams, datadir::String)

    techspath = joinpath(datadir, "existing_techs.csv")
    techs = readdlm(techspath, ',')

    validate_columns(techs,
        ["tech", "category", "fuel", "heat_rate", "startup_heat", "cost_vom",
         "unit_size", "min_gen", "max_ramp", "min_uptime", "min_downtime"],
        techspath)

    allunique(techs[:,1]) || error("Duplicate technology names in $techspath")

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])

        fuelname = string(techs[r, 3])

        heat_rate = Float64(techs[r, 4]) * powerunits_MW
        startup_heat = Float64(techs[r, 5])

        cost_vom = Float64(techs[r, 6]) * powerunits_MW

        unit_size = Float64(techs[r, 7]) / powerunits_MW
        min_gen = Float64(techs[r, 8]) / powerunits_MW
        max_ramp = Float64(techs[r, 9]) / powerunits_MW
        min_uptime = Int(techs[r, 10])
        min_downtime = Int(techs[r, 11])

        _, fuel = getbyname(system.fuels, fuelname)

        tech = ThermalExistingParams(
            techname, category, fuel, heat_rate, startup_heat, cost_vom,
            unit_size, min_gen, max_ramp, min_uptime, min_downtime,
            ThermalExistingSiteParams[])

        push!(system.thermaltechs_existing, tech)

    end

end

function load_existing_thermalsites!(system::SystemParams, datadir::String)

    n_timesteps = length(system.timesteps)
    techs = techset(system, ThermalExistingParams)

    sitespath = joinpath(datadir, "existing_sites.csv")
    sites = readdlm(sitespath, ',')

    validate_columns(sites,
        ["tech", "site", "units"], sitespath)

    allunique(tuple.(sites[:,1], sites[:,2])) || error("Duplicate site names in $sitespath")

    for r in 2:size(sites, 1)

        techname = string(sites[r, 1])
        sitename = string(sites[r, 2])
        
        techname in techs || error("Unknown tech $techname referenced in $sitespath")

        units = Int(sites[r, 3])

        site = ThermalExistingSiteParams(
            sitename, units,
            ones(n_timesteps), zeros(n_timesteps), ones(n_timesteps))

        tech = get_tech(system, ThermalExistingParams, techname)
        push!(tech.sites, site)

    end

    ratingpath = joinpath(datadir, "existing_rating.csv")
    load_sites_timeseries!(system, ThermalExistingParams, ratingpath,
        :rating, x -> x < 0.01 ? 0. : x)

    mttfpath = joinpath(datadir, "existing_mttf.csv")
    load_sites_timeseries!(system, ThermalExistingParams, mttfpath, :λ, x -> 1/x)

    mttrpath = joinpath(datadir, "existing_mttr.csv")
    load_sites_timeseries!(system, ThermalExistingParams, mttrpath, :μ, x -> 1/x)

end

function load_candidate_thermaltechs!(system::SystemParams, datadir::String)

    n_timesteps = length(system.timesteps)

    techspath = joinpath(datadir, "candidate_techs.csv")
    techs = readdlm(techspath, ',')

    validate_columns(techs,
        ["tech", "category", "fuel",
         "heat_rate", "startup_heat", "cost_vom", "cost_capital",
         "max_units", "unit_size", "min_gen", "max_ramp",
         "min_uptime", "min_downtime"],
        techspath)

    allunique(techs[:,1]) || error("Duplicate technology names in $techspath")

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])
        fuelname = string(techs[r, 3])

        heat_rate = Float64(techs[r, 4]) * powerunits_MW
        startup_heat = Float64(techs[r, 5])

        cost_vom = Float64(techs[r, 6]) * powerunits_MW
        cost_capital = Float64(techs[r, 7]) * powerunits_MW

        max_units = Int(techs[r, 8])

        unit_size = Float64(techs[r, 9]) / powerunits_MW
        min_gen = Float64(techs[r, 10]) / powerunits_MW
        max_ramp = Float64(techs[r, 11]) / powerunits_MW
        min_uptime = Int(techs[r, 12])
        min_downtime = Int(techs[r, 13])

        _, fuel = getbyname(system.fuels, fuelname)

        tech = ThermalCandidateParams(
            techname, category, fuel, heat_rate, startup_heat,
            cost_vom, cost_capital,
            max_units, unit_size, min_gen, max_ramp, min_uptime, min_downtime,
            ones(n_timesteps), zeros(n_timesteps), ones(n_timesteps))

        push!(system.thermaltechs_candidate, tech)

    end

    ratingpath = joinpath(datadir, "candidate_rating.csv")
    load_techs_timeseries!(system, ThermalCandidateParams, ratingpath,
        :rating, x -> x < 0.01 ? 0. : x)

    mttfpath = joinpath(datadir, "candidate_mttf.csv")
    load_techs_timeseries!(system, ThermalCandidateParams, mttfpath, :λ, x -> 1/x)

    mttrpath = joinpath(datadir, "candidate_mttr.csv")
    load_techs_timeseries!(system, ThermalCandidateParams, mttrpath, :μ, x -> 1/x)

end


function load_existing_variabletechs!(system::SystemParams, datadir::String)

    techspath = joinpath(datadir, "existing_techs.csv")

    techs = readdlm(techspath, ',')

    validate_columns(techs, ["tech", "category", "cost_generation"], techspath)
    allunique(techs[:,1]) || error("Duplicate technology names in $techspath")

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])

        cost_generation = Float64(techs[r, 3]) * powerunits_MW

        tech = VariableExistingParams(
            techname, category, cost_generation, VariableExistingSiteParams[])

        push!(system.variabletechs_existing, tech)

    end

end

function load_existing_variablesites!(system::SystemParams, datadir::String)

    n_timesteps = length(system.timesteps)

    techs = techset(system, VariableExistingParams)
    sitespath = joinpath(datadir, "existing_sites.csv")

    sites = readdlm(sitespath, ',')

    validate_columns(sites, ["tech", "site", "capacity"], sitespath)
    allunique(tuple.(sites[:,1], sites[:,2])) || error("Duplicate site names in $sitespath")

    for r in 2:size(sites, 1)

        techname = string(sites[r, 1])
        sitename = string(sites[r, 2])

        techname in techs || error("Unknown tech $techname referenced in $sitespath")

        capacity = Float64(sites[r, 3]) / powerunits_MW

        site = VariableExistingSiteParams(sitename, capacity, zeros(n_timesteps))

        tech = get_tech(system, VariableExistingParams, techname)
        push!(tech.sites, site)

    end

    availabilitiespath = joinpath(datadir, "existing_availability.csv")
    load_sites_timeseries!(system, VariableExistingParams, availabilitiespath,
        :availability, x -> x < 0.01 ? 0. : x)

end

function load_candidate_variabletechs!(system::SystemParams, datadir::String)

    techspath = joinpath(datadir, "candidate_techs.csv")

    techs = readdlm(techspath, ',')
    allunique(techs[:,1]) || error("Duplicate technology names in $techspath")

    validate_columns(
        techs, ["tech", "category", "cost_capital", "cost_generation"], techspath)

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])

        cost_capital = Float64(techs[r, 3]) * powerunits_MW
        cost_generation = Float64(techs[r, 4]) * powerunits_MW

        tech = VariableCandidateParams(
            techname, category, cost_capital, cost_generation, VariableCandidateSiteParams[])

        push!(system.variabletechs_candidate, tech)

    end

end

function load_candidate_variablesites!(system::SystemParams, datadir::String)

    n_timesteps = length(system.timesteps)

    techs = techset(system, VariableCandidateParams)
    sitespath = joinpath(datadir, "candidate_sites.csv")

    sites = readdlm(sitespath, ',')

    validate_columns(
        sites, ["tech", "site", "capacity_max"], sitespath)
    allunique(tuple.(sites[:,1], sites[:,2])) || error("Duplicate site names in $sitespath")

    for r in 2:size(sites, 1)

        techname = string(sites[r, 1])
        sitename = string(sites[r, 2])

        techname in techs || error("Unknown tech $techname referenced in $sitespath")

        capacity_max = Float64(sites[r, 3]) / powerunits_MW

        site = VariableCandidateSiteParams(
            sitename, capacity_max, zeros(n_timesteps))

        tech = get_tech(system, VariableCandidateParams, techname)
        push!(tech.sites, site)

    end

    availabilitiespath = joinpath(datadir, "candidate_availability.csv")
    load_sites_timeseries!(system, VariableCandidateParams, availabilitiespath,
        :availability, x -> x < 0.01 ? 0. : x)

end

function load_existing_storagetechs!(system::SystemParams, datadir::String)

    techspath = joinpath(datadir, "existing_techs.csv")

    techs = readdlm(techspath, ',')

    validate_columns(
        techs,
        ["tech", "category", "duration", "cost_operation", "roundtrip_efficiency"],
        techspath)

    allunique(techs[:,1]) || error("Duplicate technology names in $techspath")

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])

        duration = Float64(techs[r, 3])
        cost_operation = Float64(techs[r, 4]) * powerunits_MW
        roundtrip_efficiency = Float64(techs[r, 5])

        tech = StorageExistingParams(
            techname, category, cost_operation, roundtrip_efficiency,
            duration, StorageExistingSiteParams[])

        push!(system.storagetechs_existing, tech)

    end

end

function load_existing_storagesites!(system::SystemParams, datadir::String)

    techs = techset(system, StorageExistingParams)
    sitespath = joinpath(datadir, "existing_sites.csv")

    sites = readdlm(sitespath, ',')

    validate_columns(sites, ["tech", "site", "power"], sitespath)
    allunique(tuple.(sites[:,1], sites[:,2])) || error("Duplicate site names in $sitespath")

    for r in 2:size(sites, 1)

        techname = string(sites[r, 1])
        sitename = string(sites[r, 2])

        techname in techs || error("Unknown tech $techname referenced in $sitespath")

        power = Float64(sites[r, 3]) / powerunits_MW

        site = StorageExistingSiteParams(sitename, power)

        tech = get_tech(system, StorageExistingParams, regionname, techname)
        push!(tech.sites, site)

    end

end

function load_candidate_storagetechs!(system::SystemParams, datadir::String)

    techspath = joinpath(datadir, "candidate_techs.csv")

    techs = readdlm(techspath, ',')
    allunique(techs[:,1]) || error("Duplicate technology names in $techspath")

    validate_columns(
        techs,
        ["tech", "category", "cost_operation", "roundtrip_efficiency",
         "cost_capital_power", "cost_capital_energy", "power_max", "energy_max"],
        techspath)

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])

        cost_operation = Float64(techs[r, 3]) * powerunits_MW
        roundtrip_efficiency = Float64(techs[r, 4])
        cost_capital_power = Float64(techs[r, 5]) * powerunits_MW
        cost_capital_energy = Float64(techs[r, 6]) * powerunits_MW
        power_max = Float64(techs[r, 7]) / powerunits_MW
        energy_max = Float64(techs[r, 8]) / powerunits_MW

        tech = StorageCandidateParams(
            techname, category, cost_operation, roundtrip_efficiency,
            cost_capital_power, cost_capital_energy,
            power_max, energy_max)

        push!(system.storagetechs_candidate, tech)

    end

end

function load_techs_timeseries!(
    system::SystemParams, techtype::Type{<:TechnologyParams},
    datapath::String, field::Symbol, transformer::Function=identity
)

    techs = techset(system, techtype)

    data = readdlm(datapath, ',')
    allunique(data[1,2:end]) || error("Duplicate technology names in $datapath")

    timesteps = DateTime.(data[2:end, 1], dateformat"y-m-dTH:M:S.s")
    timesteps == system.timesteps ||
        error("Timestamps in $datapath are not consistent with demand data")

    for c in 2:size(data, 2)

        techname = string(data[1, c])
        techname in techs || error("Unknown tech $techname referenced in $datapath")

        tech = get_tech(system, techtype, techname)

        getfield(tech, field) .= transformer.(Float64.(data[2:end, c]))

    end

end

function load_sites_timeseries!(
    system::SystemParams, techtype::Type{<:TechnologyParams},
    datapath::String, field::Symbol, transformer::Function=identity
)

    techsites = techsiteset(system, techtype)

    data = readdlm(datapath, ',')

    timesteps = DateTime.(data[3:end, 1], dateformat"y-m-dTH:M:S.s")
    timesteps == system.timesteps ||
        error("Timestamps in $datapath are not consistent with demand data")

    for c in 2:size(data, 2)

        techname = string(data[1, c])
        sitename = string(data[2, c])
        
        (techname, sitename) in techsites ||
            error("Unknown tech-site pair ($techname, $sitename) referenced in $datapath")

        site = get_site(system, techtype, techname, sitename)

        getfield(site, field) .= transformer.(Float64.(data[3:end, c]))

    end

end

function validate_columns(
    table::Matrix,
    cols_expected::Vector{<:AbstractString},
    filepath::AbstractString
)

    for (c, expected) in enumerate(cols_expected)

        actual = table[1, c]

        actual == expected || error(
            "Unexpected name for column $c in $filepath: " *
            "expected '$expected', got '$actual'")

    end

end
