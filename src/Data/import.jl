function SystemParams(datadir::String)

    system = load_system(datadir)

    fueldir = joinpath(datadir, "fuel")
    load_fuels!(system, fueldir)

    thermaldir = joinpath(datadir, "thermal")

    existingthermaldir = joinpath(thermaldir, "existing")
    load_existing_thermaltechs!(system, existingthermaldir)
    load_existing_thermalsites!(system, existingthermaldir)

    candidatethermaldir = joinpath(thermaldir, "candidate")
    load_candidate_thermaltechs!(system, candidatethermaldir)

    variabledir = joinpath(datadir, "variable")

    existingvariabledir = joinpath(variabledir, "existing")
    load_existing_variabletechs!(system, existingvariabledir)
    load_existing_variablesites!(system, existingvariabledir)

    candidatevariabledir = joinpath(variabledir, "candidate")
    load_candidate_variabletechs!(system, candidatevariabledir)
    load_candidate_variablesites!(system, candidatevariabledir)

    storagedir = joinpath(datadir, "storage")

    existingstoragedir = joinpath(storagedir, "existing")
    load_existing_storagetechs!(system, existingstoragedir)
    load_existing_storagesites!(system, existingstoragedir)

    candidatestoragedir = joinpath(storagedir, "candidate")
    load_candidate_storagetechs!(system, candidatestoragedir)

    return system

end

function load_system(datadir::String; base_year::InvestmentYear=Int16(2025))

    name = basename(datadir)

    demandpath = joinpath(datadir, "demand.csv")
    data = readdlm(demandpath, ',')

    validate_invdata_columns(data, demandpath)

    idxs = get_dispatch_idxs(data)
    invyears = unique(x[1] for x in idxs)
    n_dispyears = maximum(x[2] for x in idxs)

    disp_daycounts = zeros(Int, n_dispyears)

    for dy in 1:n_dispyears
        disp_daycounts[dy] = maximum(x[3] for x in idxs if x[2] == dy)
    end

    times = TimeIndices(base_year, invyears, disp_daycounts)

    check_dispatchidxs(idxs, times)

    demand = shape_dispatchdata(Float64.(data[2:end, 5]) ./ powerunits_MW, times)

    return SystemParams(
        name, times, demand,
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
    validate_columns(data, ["fuel", "co2_factor"], fuelspath)

    allunique(data[2:end, 1]) || error("Duplicate site names in $sitespath")

    for f in 2:size(data, 1)

        fuelname = string(data[f, 1])
        co2_factor = Float64(data[f, 2]) * 1e-3 * powerunits_MW # kg to tonnes

        cost = defaultinvestmentdata(system.times, 0.)

        fuel = FuelParams(fuelname, cost, co2_factor)
        push!(system.fuels, fuel)

    end

    costpath = joinpath(datadir, "fuel_cost.csv")
    load_investment_timeseries!(system, FuelParams, costpath,
        :cost, x -> x * powerunits_MW)

end

function load_existing_thermaltechs!(system::SystemParams, datadir::String)

    techspath = joinpath(datadir, "techs.csv")
    techs = readdlm(techspath, ',')

    validate_columns(techs,
        ["tech", "category", "fuel", "heat_rate", "startup_heat",
         "unit_size", "min_gen", "max_ramp", "min_uptime", "min_downtime"],
        techspath)

    allunique(techs[2:end, 1]) ||
        error("Duplicate technology names in $techspath")

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])

        fuelname = string(techs[r, 3])

        heat_rate = Float64(techs[r, 4])
        startup_heat = Float64(techs[r, 5]) / powerunits_MW

        cost_vom = defaultinvestmentdata(system.times, 0.)

        unit_size = Float64(techs[r, 6]) / powerunits_MW
        rating = defaultdispatchdata(system.times, 1.)

        min_gen = Float64(techs[r, 7]) / powerunits_MW
        max_ramp = Float64(techs[r, 8]) / powerunits_MW
        min_uptime = Int(techs[r, 9])
        min_downtime = Int(techs[r, 10])

        _, fuel = get_entity(system, FuelParams, fuelname)

        tech = ThermalExistingParams(
            techname, category, fuel, heat_rate, startup_heat, cost_vom,
            unit_size, rating, min_gen, max_ramp, min_uptime, min_downtime,
            ThermalExistingSiteParams[])

        push!(system.thermaltechs_existing, tech)

    end

    load_investment_timeseries!(system, ThermalExistingParams,
        joinpath(datadir, "tech_cost_vom.csv"), :cost_vom, x -> x * powerunits_MW)

    load_dispatch_timeseries!(system, ThermalExistingParams,
        joinpath(datadir, "tech_rating.csv"), :rating, x -> x < 0.01 ? 0. : x)

end

function load_existing_thermalsites!(system::SystemParams, datadir::String)

    sitespath = joinpath(datadir, "sites.csv")
    sites = readdlm(sitespath, ',')

    validate_columns(sites, ["tech", "site"], sitespath)
    allunique(sites[2:end, 2]) || error("Duplicate site names in $sitespath")

    for r in 2:size(sites, 1)

        techname = string(sites[r, 1])
        sitename = string(sites[r, 2])

        _, tech = get_entity(system, ThermalExistingParams, techname)

        units = defaultinvestmentdata(system.times, 0)
        λ = defaultdispatchdata(system.times, 0.)
        μ = defaultdispatchdata(system.times, 1.)

        site = ThermalExistingSiteParams(sitename, units, λ, μ)

        push!(tech.sites, site)

    end

    load_investment_timeseries!(system, ThermalExistingSiteParams,
        joinpath(datadir, "site_units.csv"), :units)

    load_dispatch_timeseries!(system, ThermalExistingSiteParams,
        joinpath(datadir, "site_mttf.csv"), :λ, mttf -> 1/mttf)

    load_dispatch_timeseries!(system, ThermalExistingSiteParams,
        joinpath(datadir, "site_mttr.csv"), :μ, mttr -> 1/mttr)

end

function load_candidate_thermaltechs!(system::SystemParams, datadir::String)

    techspath = joinpath(datadir, "techs.csv")
    techs = readdlm(techspath, ',')

    validate_columns(techs,
        ["tech", "category", "fuel", "heat_rate", "startup_heat",
         "unit_size", "min_gen", "max_ramp", "min_uptime", "min_downtime"],
        techspath)

    allunique(techs[2:end, 1]) ||
        error("Duplicate technology names in $techspath")

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])

        fuelname = string(techs[r, 3])

        heat_rate = Float64(techs[r, 4])
        startup_heat = Float64(techs[r, 5]) / powerunits_MW

        cost_vom = defaultinvestmentdata(system.times, 0.)
        cost_capital = defaultinvestmentdata(system.times, 0.)

        max_units = defaultinvestmentdata(system.times, 0)

        unit_size = Float64(techs[r, 6]) / powerunits_MW
        rating = defaultdispatchdata(system.times, 1.)

        min_gen = Float64(techs[r, 7]) / powerunits_MW
        max_ramp = Float64(techs[r, 8]) / powerunits_MW
        min_uptime = Int(techs[r, 9])
        min_downtime = Int(techs[r, 10])

        λ = defaultdispatchdata(system.times, 0.)
        μ = defaultdispatchdata(system.times, 1.)

        _, fuel = get_entity(system, FuelParams, fuelname)

        tech = ThermalCandidateParams(
            techname, category, fuel, heat_rate, startup_heat,
            cost_vom, cost_capital, max_units, unit_size, rating,
            min_gen, max_ramp, min_uptime, min_downtime, λ, μ)

        push!(system.thermaltechs_candidate, tech)

    end

    load_investment_timeseries!(system, ThermalCandidateParams,
        joinpath(datadir, "tech_cost_vom.csv"), :cost_vom, x -> x * powerunits_MW)

    load_investment_timeseries!(system, ThermalCandidateParams,
        joinpath(datadir, "tech_cost_capital.csv"), :cost_capital, x -> x * powerunits_MW)

    load_investment_timeseries!(system, ThermalCandidateParams,
        joinpath(datadir, "tech_max_units.csv"), :max_units)

    load_dispatch_timeseries!(system, ThermalCandidateParams,
        joinpath(datadir, "tech_rating.csv"), :rating, x -> x < 0.01 ? 0. : x)

    load_dispatch_timeseries!(system, ThermalCandidateParams,
        joinpath(datadir, "tech_mttf.csv"), :λ, mttf -> 1/mttf)

    load_dispatch_timeseries!(system, ThermalCandidateParams,
        joinpath(datadir, "tech_mttr.csv"), :μ, mttr -> 1/mttr)

end


function load_existing_variabletechs!(system::SystemParams, datadir::String)

    techspath = joinpath(datadir, "techs.csv")
    techs = readdlm(techspath, ',')

    validate_columns(techs, ["tech", "category"], techspath)

    allunique(techs[2:end, 1]) ||
        error("Duplicate technology names in $techspath")

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])

        cost_vom = defaultinvestmentdata(system.times, 0.)

        tech = VariableExistingParams(
            techname, category, cost_vom, VariableExistingSiteParams[])

        push!(system.variabletechs_existing, tech)

    end

    load_investment_timeseries!(system, VariableExistingParams,
        joinpath(datadir, "tech_cost_vom.csv"), :cost_vom, x -> x * powerunits_MW)

end

function load_existing_variablesites!(system::SystemParams, datadir::String)

    sitespath = joinpath(datadir, "sites.csv")
    sites = readdlm(sitespath, ',')

    validate_columns(sites, ["tech", "site"], sitespath)
    allunique(sites[2:end, 2]) || error("Duplicate site names in $sitespath")

    for r in 2:size(sites, 1)

        techname = string(sites[r, 1])
        sitename = string(sites[r, 2])

        _, tech = get_entity(system, VariableExistingParams, techname)

        capacity = defaultinvestmentdata(system.times, 0)
        availability = defaultdispatchdata(system.times, 1.)

        site = VariableExistingSiteParams(sitename, capacity, availability)

        push!(tech.sites, site)

    end

    load_investment_timeseries!(system, VariableExistingSiteParams,
        joinpath(datadir, "site_capacity.csv"), :capacity,
        x -> x / powerunits_MW)

    load_dispatch_timeseries!(system, VariableExistingSiteParams,
        joinpath(datadir, "site_availability.csv"), :availability,
        x -> x < 0.01 ? 0. : x)

end

function load_candidate_variabletechs!(system::SystemParams, datadir::String)

    techspath = joinpath(datadir, "techs.csv")
    techs = readdlm(techspath, ',')

    validate_columns(techs, ["tech", "category"], techspath)

    allunique(techs[2:end, 1]) ||
        error("Duplicate technology names in $techspath")

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])

        cost_capital = defaultinvestmentdata(system.times, 0.)
        cost_vom = defaultinvestmentdata(system.times, 0.)

        tech = VariableCandidateParams(
            techname, category, cost_capital, cost_vom,
            VariableCandidateSiteParams[])

        push!(system.variabletechs_candidate, tech)

    end

    load_investment_timeseries!(system, VariableCandidateParams,
        joinpath(datadir, "tech_cost_vom.csv"), :cost_vom, x -> x * powerunits_MW)

    load_investment_timeseries!(system, VariableCandidateParams,
        joinpath(datadir, "tech_cost_capital.csv"), :cost_capital, x -> x * powerunits_MW)

end

function load_candidate_variablesites!(system::SystemParams, datadir::String)

    sitespath = joinpath(datadir, "sites.csv")
    sites = readdlm(sitespath, ',')

    validate_columns(sites, ["tech", "site"], sitespath)
    allunique(sites[2:end, 2]) || error("Duplicate site names in $sitespath")

    for r in 2:size(sites, 1)

        techname = string(sites[r, 1])
        sitename = string(sites[r, 2])

        _, tech = get_entity(system, VariableCandidateParams, techname)

        capacity_max = defaultinvestmentdata(system.times, 0.)
        availabililty = defaultdispatchdata(system.times, 1.)

        site = VariableCandidateSiteParams(
            sitename, capacity_max, availabililty)

        push!(tech.sites, site)

    end

    load_investment_timeseries!(system, VariableCandidateSiteParams,
        joinpath(datadir, "site_capacity_max.csv"), :capacity_max,
        x -> x / powerunits_MW)

    load_dispatch_timeseries!(system, VariableCandidateSiteParams,
        joinpath(datadir, "site_availability.csv"), :availability,
        x -> x < 0.01 ? 0. : x)

end

function load_existing_storagetechs!(system::SystemParams, datadir::String)

    techspath = joinpath(datadir, "techs.csv")
    techs = readdlm(techspath, ',')

    validate_columns(
        techs, ["tech", "category", "duration", "roundtrip_efficiency"],
        techspath)

    allunique(techs[2:end, 1]) ||
        error("Duplicate technology names in $techspath")

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])

        # We need duration to be able to change over years internally, but don't
        # want to expose this to the user in the input format
        duration = defaultinvestmentdata(system.times, Float64(techs[r, 3]))

        roundtrip_efficiency = Float64(techs[r, 4])

        cost_vom = defaultinvestmentdata(system.times, 0.)

        tech = StorageExistingParams(
            techname, category, duration, roundtrip_efficiency, cost_vom,
            StorageExistingSiteParams[])

        push!(system.storagetechs_existing, tech)

    end

    load_investment_timeseries!(system, StorageExistingParams,
        joinpath(datadir, "tech_cost_vom.csv"), :cost_vom, x -> x * powerunits_MW)

end

function load_existing_storagesites!(system::SystemParams, datadir::String)

    sitespath = joinpath(datadir, "sites.csv")
    sites = readdlm(sitespath, ',')

    validate_columns(sites, ["tech", "site"], sitespath)
    allunique(sites[2:end, 2]) || error("Duplicate site names in $sitespath")

    for r in 2:size(sites, 1)

        techname = string(sites[r, 1])
        sitename = string(sites[r, 2])

        _, tech = get_entity(system, StorageExistingParams, techname)

capacity = defaultinvestmentdata(system.times, 0)

        site = StorageExistingSiteParams(sitename, capacity)

        push!(tech.sites, site)

    end

    load_investment_timeseries!(system, StorageExistingSiteParams,
        joinpath(datadir, "site_capacity.csv"), :capacity,
        x -> x / powerunits_MW)

end

function load_candidate_storagetechs!(system::SystemParams, datadir::String)

    techspath = joinpath(datadir, "techs.csv")
    techs = readdlm(techspath, ',')

    validate_columns(
        techs, ["tech", "category", "roundtrip_efficiency"], techspath)

    allunique(techs[2:end, 1]) ||
        error("Duplicate technology names in $techspath")

    for r in 2:size(techs, 1)

        techname = string(techs[r, 1])
        category = string(techs[r, 2])

        roundtrip_efficiency = Float64(techs[r, 3])

        cost_vom = defaultinvestmentdata(system.times, 0.)
        cost_capital_power = defaultinvestmentdata(system.times, 0.)
        cost_capital_energy = defaultinvestmentdata(system.times, 0.)

        power_max = defaultinvestmentdata(system.times, 0.)
        energy_max = defaultinvestmentdata(system.times, 0.)

        tech = StorageCandidateParams(
            techname, category, roundtrip_efficiency,
            cost_vom, cost_capital_power, cost_capital_energy,
            power_max, energy_max)

        push!(system.storagetechs_candidate, tech)

    end

    load_investment_timeseries!(system, StorageCandidateParams,
        joinpath(datadir, "tech_cost_vom.csv"), :cost_vom,
        x -> x * powerunits_MW)

    load_investment_timeseries!(system, StorageCandidateParams,
        joinpath(datadir, "tech_cost_capital_power.csv"), :cost_capital_power,
        x -> x * powerunits_MW)

    load_investment_timeseries!(system, StorageCandidateParams,
        joinpath(datadir, "tech_cost_capital_energy.csv"), :cost_capital_energy,
        x -> x * powerunits_MW)

    load_investment_timeseries!(system, StorageCandidateParams,
        joinpath(datadir, "tech_power_max.csv"), :power_max,
        x -> x / powerunits_MW)

    load_investment_timeseries!(system, StorageCandidateParams,
        joinpath(datadir, "tech_energy_max.csv"), :energy_max,
        x -> x / powerunits_MW)

end

# Should we allow skipping data loading if the input file doesn't exist
# (default values just won't be replaced)?

function load_investment_timeseries!(
    system::SystemParams, entitytype::Type{<:EntityParams},
    datapath::String, field::Symbol, transformer::Function=identity
)

    data = readdlm(datapath, ',')
    validate_invdata_columns(data, datapath)

    idxs = get_investment_idxs(data)
    check_investmentidxs(idxs, system.times)

    load_timeseries!(system, data, 2, entitytype, datapath, field,
                     shape_investmentdata, transformer)

end

function load_dispatch_timeseries!(
    system::SystemParams, entitytype::Type{<:EntityParams},
    datapath::String, field::Symbol, transformer::Function=identity
)

    data = readdlm(datapath, ',')
    validate_dispdata_columns(data, datapath)

    idxs = get_dispatch_idxs(data)
    check_dispatchidxs(idxs, system.times)

    load_timeseries!(system, data, 5, entitytype, datapath, field,
                     shape_dispatchdata, transformer)

end

function load_timeseries!(
    system::SystemParams, data::Matrix, startcol::Int,
    entitytype::Type{T},
    datapath::String, field::Symbol,
    shaper::Function, transformer::Function=identity
) where T <: EntityParams

    colnames = data[1, startcol:end]
    validcols = entitynames(system, entitytype)

    allunique(colnames) || error("Duplicate $T names in $datapath")
    all(c -> c in validcols, colnames) || error("Invalid $T name in $datapath")

    for c in startcol:size(data, 2)
        entityname = string(data[1, c])
        _, entity = get_entity(system, entitytype, entityname)
        getfield(entity, field) .= shaper(
            transformer.(Float64.(data[2:end, c])), system.times)
    end

end

# Are default values the right answer? Or should we require explicitly
# providing all values for all entities? Defaults are convenient, but
# can lead to surprises if you forget to provide something
defaultinvestmentdata(times::TimeIndices, val::T) where T =
    fill(val, n_investment_years(times))

defaultdispatchdata(times::TimeIndices, val::T) where T =
    fill(val, N_HOURS_IN_DAY, n_dispatch_days(times), n_investment_years(times))

validate_invdata_columns(data::Matrix, path::AbstractString) =
    validate_timeseries_columns(data, ["investment_year"], path)

get_investment_idxs(data::Matrix) = Int.(data[2:end, 1])

validate_dispdata_columns(data::Matrix, path::AbstractString) =
    validate_timeseries_columns(data, ["investment_year", "dispatch_year", "day", "hour"], path)

get_dispatch_idxs(data::Matrix) = [tuple(
    Int(data[i, 1]), Int(data[i, 2]), Int(data[i, 3]), Int(data[i, 4]),
    ) for i in 2:size(data,1)]

function validate_timeseries_columns(
    data::Matrix, staticcols::Vector{<:AbstractString}, path::AbstractString)

    last_staticcol = length(staticcols)

    validate_columns(data[:, 1:last_staticcol], staticcols, path)

    allunique(data[1,(last_staticcol+1):end]) ||
        error("Duplicate column names in $path")

    return

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
