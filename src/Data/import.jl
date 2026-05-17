function SystemParams(datadir::String, outages_type::String="static")

    name = basename(datadir)

    regions, timesteps = load_regions(datadir)

    interfaces = load_interfaces(datadir, regions)
    system = SystemParams(name, timesteps, regions, interfaces)

    thermaldir = joinpath(datadir, "thermal")

    load_existing_thermaltechs!(system, thermaldir)

    load_existing_thermalsites!(system, thermaldir, outages_type)
    load_candidate_thermaltechs!(system, thermaldir, outages_type)

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

function load_regions(datadir::String)

    regionpath = joinpath(datadir, "regions.csv")
    data = readdlm(regionpath, ',')

    timestamps_raw = DateTime.(data[2:end, 1], dateformat"y-m-dTH:M:S.s")
    timestamps = first(timestamps_raw):Hour(1):last(timestamps_raw)

    timestamps == timestamps_raw ||
        error("Input timesteps should be hourly")

    regions = RegionParams[]
    regionnames = Set{String}()

    for c in 2:size(data, 2)

        regionname = String(data[1, c])
        demand = Float64.(data[2:end, c]) / powerunits_MW

        regionname in regionnames &&
            error("Region name $regionname is duplicated in $regionpath")

        region = RegionParams(
            regionname, demand,
            ThermalExistingParams[],
            ThermalCandidateParams[],
            VariableExistingParams[],
            VariableCandidateParams[],
            StorageExistingParams[],
            StorageCandidateParams[],
            Int[], Int[] # Region indices
        )

        push!(regionnames, regionname)
        push!(regions, region)

    end

    return regions, timestamps

end

function load_interfaces(datadir::String, regions::Vector{RegionParams})

    data = readdlm(joinpath(datadir, "transmission.csv"), ',')
    interfaces = InterfaceParams[]

    for i in 2:size(data, 1)

        iface_idx = i-1

        name = string(data[i,1])
        region_from = string(data[i,2])
        region_to = string(data[i,3])
        cost_capital = Float64(data[i,4]) * powerunits_MW
        capacity_existing = Float64(data[i,5]) / powerunits_MW
        capacity_new_max = Float64(data[i,6]) / powerunits_MW

        from_idx, region_from = getbyname(regions, region_from)
        to_idx, region_to = getbyname(regions, region_to)

        interface = InterfaceParams(
            name, from_idx, to_idx, cost_capital,
            capacity_existing, capacity_new_max)

        push!(region_from.export_interfaces, iface_idx)
        push!(region_to.import_interfaces, iface_idx)
        push!(interfaces, interface)

    end

    return interfaces

end

function load_existing_thermaltechs!(system::SystemParams, datadir::String)

    regions = regionset(system)
    techspath = joinpath(datadir, "existing_techs.csv")
    validator = AddValidator{String}("region", regions, "tech", techspath)
    techs = readdlm(techspath, ',')

    validate_columns(
        techs, ["region", "tech", "category", "cost_generation"],
        techspath)

    for r in 2:size(techs, 1)

        regionname = string(techs[r, 1])
        techname = string(techs[r, 2])
        category = string(techs[r, 3])

        validate!(validator, regionname, techname)

        cost_generation = Float64(techs[r, 4]) * powerunits_MW

        tech = ThermalExistingParams(
            techname, category, cost_generation, ThermalExistingSiteParams[])

        _, region = getbyname(system.regions, regionname)
        push!(region.thermaltechs_existing, tech)

    end

end

function load_existing_thermalsites!(system::SystemParams, datadir::String, outages_type::String)

    n_timesteps = length(system.timesteps)

    regiontechs = regiontechset(system, ThermalExistingParams)
    sitespath = joinpath(datadir, "existing_sites.csv")
    validator = AddValidator{String}(
        "region-technology pair", regiontechs, "site", sitespath)

    sites = readdlm(sitespath, ',')

    validate_columns(sites,
        ["region", "tech", "site", "units", "unit_size"], sitespath)

    for r in 2:size(sites, 1)

        regionname = string(sites[r, 1])
        techname = string(sites[r, 2])
        sitename = string(sites[r, 3])

        validate!(validator, (regionname, techname), sitename)

        units = Int(sites[r, 4])
        unit_size = Float64(sites[r, 5]) / powerunits_MW

        site = ThermalExistingSiteParams(
            sitename, units, unit_size,
            ones(n_timesteps), zeros(n_timesteps), ones(n_timesteps))

        tech = get_tech(system, ThermalExistingParams, regionname, techname)
        push!(tech.sites, site)

    end

    if outages_type == "time_dep"
        mttfpath = joinpath(datadir, "existing_time_dep_mttf.csv")    
        mttrpath = joinpath(datadir, "existing_time_dep_mttr.csv")
        
        # load time-dep deratings for time-dep RAM
        ratingpath = joinpath(datadir, "existing_rating.csv")
        load_sites_timeseries!(system, ThermalExistingParams, ratingpath,
        :rating, x -> x < 0.01 ? 0. : x)
    else
        mttfpath = joinpath(datadir, "existing_mttf.csv")    
        mttrpath = joinpath(datadir, "existing_mttr.csv")
    end

    load_sites_timeseries!(system, ThermalExistingParams, mttfpath, :λ, x -> 1/x)
    load_sites_timeseries!(system, ThermalExistingParams, mttrpath, :μ, x -> 1/x)

end

function load_candidate_thermaltechs!(system::SystemParams, datadir::String, outages_type::String)

    n_timesteps = length(system.timesteps)

    regions = regionset(system)
    techspath = joinpath(datadir, "candidate_techs.csv")
    validator = AddValidator{String}("region", regions, "tech", techspath)
    techs = readdlm(techspath, ',')

    validate_columns(techs,
        ["region", "tech", "category",
         "cost_capital", "cost_generation", "unit_size", "max_units"],
        techspath)

    for r in 2:size(techs, 1)

        regionname = string(techs[r, 1])
        techname = string(techs[r, 2])
        category = string(techs[r, 3])

        validate!(validator, regionname, techname)

        cost_capital = Float64(techs[r, 4]) * powerunits_MW
        cost_generation = Float64(techs[r, 5]) * powerunits_MW
        unit_size = Float64(techs[r, 6]) / powerunits_MW
        max_units = Int(techs[r, 7])

        tech = ThermalCandidateParams(
            techname, category, cost_generation, cost_capital,
            max_units, unit_size,
            ones(n_timesteps), zeros(n_timesteps), ones(n_timesteps))

        _, region = getbyname(system.regions, regionname)
        push!(region.thermaltechs_candidate, tech)

    end

    if outages_type == "time_dep"
        mttfpath = joinpath(datadir, "candidate_time_dep_mttf.csv")    
        mttrpath = joinpath(datadir, "candidate_time_dep_mttr.csv")
        
        # load time-dep deratings for time-dep RAM
        ratingpath = joinpath(datadir, "candidate_rating.csv")
        load_techs_timeseries!(system, ThermalCandidateParams, ratingpath,
        :rating, x -> x < 0.01 ? 0. : x)
    else
        mttfpath = joinpath(datadir, "candidate_mttf.csv")    
        mttrpath = joinpath(datadir, "candidate_mttr.csv")
    end

    load_techs_timeseries!(system, ThermalCandidateParams, mttfpath, :λ, x -> 1/x)
    load_techs_timeseries!(system, ThermalCandidateParams, mttrpath, :μ, x -> 1/x)    

end


function load_existing_variabletechs!(system::SystemParams, datadir::String)

    regions = regionset(system)
    techspath = joinpath(datadir, "existing_techs.csv")
    validator = AddValidator{String}("region", regions, "tech", techspath)

    techs = readdlm(techspath, ',')

    validate_columns(
        techs, ["region", "tech", "category", "cost_generation"],
        techspath)

    for r in 2:size(techs, 1)

        regionname = string(techs[r, 1])
        techname = string(techs[r, 2])
        category = string(techs[r, 3])

        validate!(validator, regionname, techname)

        cost_generation = Float64(techs[r, 4]) * powerunits_MW

        tech = VariableExistingParams(
            techname, category, cost_generation, VariableExistingSiteParams[])

        _, region = getbyname(system.regions, regionname)
        push!(region.variabletechs_existing, tech)

    end

end

function load_existing_variablesites!(system::SystemParams, datadir::String)

    n_timesteps = length(system.timesteps)

    regiontechs = regiontechset(system, VariableExistingParams)
    sitespath = joinpath(datadir, "existing_sites.csv")
    validator = AddValidator{String}(
        "region-technology pair", regiontechs, "site", sitespath)

    sites = readdlm(sitespath, ',')

    validate_columns(sites, ["region", "tech", "site", "capacity"], sitespath)

    for r in 2:size(sites, 1)

        regionname = string(sites[r, 1])
        techname = string(sites[r, 2])
        sitename = string(sites[r, 3])

        validate!(validator, (regionname, techname), sitename)

        capacity = Float64(sites[r, 4]) / powerunits_MW

        site = VariableExistingSiteParams(
            sitename, capacity, zeros(n_timesteps))

        tech = get_tech(system, VariableExistingParams, regionname, techname)
        push!(tech.sites, site)

    end

    availabilitiespath = joinpath(datadir, "existing_availability.csv")
    load_sites_timeseries!(system, VariableExistingParams, availabilitiespath,
        :availability, x -> x < 0.01 ? 0. : x)

end

function load_candidate_variabletechs!(system::SystemParams, datadir::String)

    regions = regionset(system)
    techspath = joinpath(datadir, "candidate_techs.csv")
    validator = AddValidator{String}("region", regions, "tech", techspath)

    techs = readdlm(techspath, ',')

    validate_columns(
        techs, ["region", "tech", "category", "cost_capital", "cost_generation"],
        techspath)

    for r in 2:size(techs, 1)

        regionname = string(techs[r, 1])
        techname = string(techs[r, 2])
        category = string(techs[r, 3])

        validate!(validator, regionname, techname)

        cost_capital = Float64(techs[r, 4]) * powerunits_MW
        cost_generation = Float64(techs[r, 5]) * powerunits_MW

        tech = VariableCandidateParams(
            techname, category, cost_capital, cost_generation, VariableCandidateSiteParams[])

        _, region = getbyname(system.regions, regionname)
        push!(region.variabletechs_candidate, tech)

    end

end

function load_candidate_variablesites!(system::SystemParams, datadir::String)

    n_timesteps = length(system.timesteps)

    regiontechs = regiontechset(system, VariableCandidateParams)
    sitespath = joinpath(datadir, "candidate_sites.csv")
    validator = AddValidator{String}(
        "region-technology pair", regiontechs, "site", sitespath)

    sites = readdlm(sitespath, ',')

    validate_columns(
        sites, ["region", "tech", "site", "capacity_max"], sitespath)

    for r in 2:size(sites, 1)

        regionname = string(sites[r, 1])
        techname = string(sites[r, 2])
        sitename = string(sites[r, 3])

        validate!(validator, (regionname, techname), sitename)

        capacity_max = Float64(sites[r, 4]) / powerunits_MW

        site = VariableCandidateSiteParams(
            sitename, capacity_max, zeros(n_timesteps))

        tech = get_tech(system, VariableCandidateParams, regionname, techname)
        push!(tech.sites, site)

    end

    availabilitiespath = joinpath(datadir, "candidate_availability.csv")
    load_sites_timeseries!(system, VariableCandidateParams, availabilitiespath,
        :availability, x -> x < 0.01 ? 0. : x)

end

function load_existing_storagetechs!(system::SystemParams, datadir::String)

    regions = regionset(system)
    techspath = joinpath(datadir, "existing_techs.csv")
    validator = AddValidator{String}("region", regions, "tech", techspath)

    techs = readdlm(techspath, ',')

    validate_columns(
        techs,
        ["region", "tech", "category",
         "duration", "cost_operation", "roundtrip_efficiency"],
        techspath)

    for r in 2:size(techs, 1)

        regionname = string(techs[r, 1])
        techname = string(techs[r, 2])
        category = string(techs[r, 3])

        validate!(validator, regionname, techname)

        duration = Float64(techs[r, 4])
        cost_operation = Float64(techs[r, 5]) * powerunits_MW
        roundtrip_efficiency = Float64(techs[r, 6])

        tech = StorageExistingParams(
            techname, category, cost_operation, roundtrip_efficiency,
            duration, StorageExistingSiteParams[])

        _, region = getbyname(system.regions, regionname)
        push!(region.storagetechs_existing, tech)

    end

end

function load_existing_storagesites!(system::SystemParams, datadir::String)

    regiontechs = regiontechset(system, StorageExistingParams)
    sitespath = joinpath(datadir, "existing_sites.csv")
    validator = AddValidator{String}(
        "region-technology pair", regiontechs, "site", sitespath)

    sites = readdlm(sitespath, ',')

    validate_columns(sites, ["region", "tech", "site", "power"], sitespath)

    for r in 2:size(sites, 1)

        regionname = string(sites[r, 1])
        techname = string(sites[r, 2])
        sitename = string(sites[r, 3])

        validate!(validator, (regionname, techname), sitename)

        power = Float64(sites[r, 4]) / powerunits_MW

        site = StorageExistingSiteParams(sitename, power)

        tech = get_tech(system, StorageExistingParams, regionname, techname)
        push!(tech.sites, site)

    end

end

function load_candidate_storagetechs!(system::SystemParams, datadir::String)

    regions = regionset(system)
    techspath = joinpath(datadir, "candidate_techs.csv")
    validator = AddValidator{String}("region", regions, "tech", techspath)

    techs = readdlm(techspath, ',')

    validate_columns(
        techs,
        ["region", "tech", "category",
         "cost_operation", "roundtrip_efficiency",
         "cost_capital_power", "cost_capital_energy",
         "power_max", "energy_max"],
        techspath)

    for r in 2:size(techs, 1)

        regionname = string(techs[r, 1])
        techname = string(techs[r, 2])
        category = string(techs[r, 3])

        validate!(validator, regionname, techname)

        cost_operation = Float64(techs[r, 4]) * powerunits_MW
        roundtrip_efficiency = Float64(techs[r, 5])
        cost_capital_power = Float64(techs[r, 6]) * powerunits_MW
        cost_capital_energy = Float64(techs[r, 7]) * powerunits_MW
        power_max = Float64(techs[r, 8]) / powerunits_MW
        energy_max = Float64(techs[r, 9]) / powerunits_MW

        tech = StorageCandidateParams(
            techname, category, cost_operation, roundtrip_efficiency,
            cost_capital_power, cost_capital_energy,
            power_max, energy_max)

        _, region = getbyname(system.regions, regionname)
        push!(region.storagetechs_candidate, tech)

    end

end

function load_techs_timeseries!(
    system::SystemParams, techtype::Type{<:TechnologyParams},
    datapath::String, field::Symbol, transformer::Function=identity
)

    validator = UpdateValidator(
        "region-technology pair",
        datapath,
        regiontechset(system, techtype)
    )

    data = readdlm(datapath, ',')

    timesteps = DateTime.(data[3:end, 1], dateformat"y-m-dTH:M:S.s")
    timesteps == system.timesteps ||
        error("Timestamps in $datapath are not consistent with demand data")

    for c in 2:size(data, 2)

        regionname = string(data[1, c])
        techname = string(data[2, c])

        validate!(validator, (regionname, techname))

        tech = get_tech(
            system, techtype, regionname, techname)

        getfield(tech, field) .= transformer.(Float64.(data[3:end, c]))

    end

end

function load_sites_timeseries!(
    system::SystemParams, techtype::Type{<:TechnologyParams},
    datapath::String, field::Symbol, transformer::Function=identity
)

    validator = UpdateValidator(
        "region-technology-site triple ",
        datapath,
        regiontechsiteset(system, techtype)
    )

    data = readdlm(datapath, ',')

    timesteps = DateTime.(data[4:end, 1], dateformat"y-m-dTH:M:S.s")
    timesteps == system.timesteps ||
        error("Timestamps in $datapath are not consistent with demand data")

    for c in 2:size(data, 2)

        regionname = string(data[1, c])
        techname = string(data[2, c])
        sitename = string(data[3, c])

        validate!(validator, (regionname, techname, sitename))

        site = get_site(
            system, techtype, regionname, techname, sitename)

        getfield(site, field) .= transformer.(Float64.(data[4:end, c]))

    end

end
