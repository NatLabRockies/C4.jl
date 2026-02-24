import DBInterface
import DuckDB

import ..store, ..powerunits_MW

struct DataAppender

    regions::DuckDB.Appender
    techs::DuckDB.Appender
    sites::DuckDB.Appender
    interfaces::DuckDB.Appender

    DataAppender(con::DuckDB.DB) = new(
        DuckDB.Appender(con, "regions"),
        DuckDB.Appender(con, "techs"),
        DuckDB.Appender(con, "sites"),
        DuckDB.Appender(con, "interfaces")
    )

end

function DuckDB.close(appender::DataAppender)
    DuckDB.close(appender.regions)
    DuckDB.close(appender.techs)
    DuckDB.close(appender.sites)
    DuckDB.close(appender.interfaces)
    return
end

function store(con::DuckDB.DB, sys::SystemParams)

    DBInterface.execute(con, "CREATE TABLE regions (
        region TEXT PRIMARY KEY
    )")

    DBInterface.execute(con, "CREATE TABLE techtypes (
        techtype TEXT PRIMARY KEY
    )")

    DBInterface.execute(con, "INSERT INTO techtypes VALUES
        ('thermal'),
        ('variable'),
        ('storage')")

    DBInterface.execute(con, "CREATE TABLE techs (
        tech TEXT,
        region TEXT REFERENCES regions(region),
        techtype TEXT REFERENCES techtypes(techtype),
        cost_generation DOUBLE,
        cost_capital_power DOUBLE,
        cost_capital_energy DOUBLE,
        PRIMARY KEY (tech, region)
    )")

    DBInterface.execute(con, "CREATE TABLE sites (
        site TEXT,
        tech TEXT,
        region TEXT,
        FOREIGN KEY (tech, region) REFERENCES techs (tech, region),
        PRIMARY KEY (site, tech, region)
    )")

    DBInterface.execute(con, "CREATE TABLE interfaces (
        region_from TEXT REFERENCES regions(region),
        region_to TEXT REFERENCES regions(region),
        cost_capital DOUBLE,
        PRIMARY KEY (region_from, region_to),
    )")

    appender = DataAppender(con)

    foreach(region -> store(appender, region), sys.regions)
    foreach(iface -> store(appender, iface, sys.regions), sys.interfaces)

    DuckDB.close(appender)

    DBInterface.execute(con, "CREATE TABLE iterations (
        id INTEGER PRIMARY KEY
    )")

    DBInterface.execute(con, "CREATE TABLE iteration_steps (
        iteration INTEGER REFERENCES iterations(id),
        step TEXT,
        t_start TIMESTAMP,
        t_end TIMESTAMP,
        PRIMARY KEY (iteration, step),
    )")

    return

end

function store(appender::DataAppender, region::RegionParams)

    DuckDB.append(appender.regions, region.name)
    DuckDB.end_row(appender.regions)

    foreach(tech -> store(appender, tech, region), region.thermaltechs_existing)
    foreach(tech -> store(appender, tech, region), region.thermaltechs_candidate)

    foreach(tech -> store(appender, tech, region), region.variabletechs_existing)
    foreach(tech -> store(appender, tech, region), region.variabletechs_candidate)

    foreach(tech -> store(appender, tech, region), region.storagetechs_existing)
    foreach(tech -> store(appender, tech, region), region.storagetechs_candidate)

end

function store(
    appender::DataAppender,
    tech::VariableExistingParams,
    region::RegionParams)

    DuckDB.append(appender.techs, tech.name)
    DuckDB.append(appender.techs, region.name)
    DuckDB.append(appender.techs, "variable")
    DuckDB.append(appender.techs, tech.cost_generation / powerunits_MW)
    DuckDB.append(appender.techs, nothing)
    DuckDB.append(appender.techs, nothing)
    DuckDB.end_row(appender.techs)

    foreach(site -> store(appender, site, tech, region), tech.sites)

end

function store(
    appender::DataAppender,
    params::VariableCandidateParams,
    region::RegionParams)

    DuckDB.append(appender.techs, params.name)
    DuckDB.append(appender.techs, region.name)
    DuckDB.append(appender.techs, "variable")
    DuckDB.append(appender.techs, params.cost_generation / powerunits_MW)
    DuckDB.append(appender.techs, params.cost_capital / powerunits_MW)
    DuckDB.append(appender.techs, nothing)
    DuckDB.end_row(appender.techs)

    foreach(site -> store(appender, site, params, region), params.sites)

end

function store(
    appender::DataAppender,
    tech::ThermalExistingParams,
    region::RegionParams)

    DuckDB.append(appender.techs, tech.name)
    DuckDB.append(appender.techs, region.name)
    DuckDB.append(appender.techs, "thermal")
    DuckDB.append(appender.techs, tech.cost_generation / powerunits_MW)
    DuckDB.append(appender.techs, nothing)
    DuckDB.append(appender.techs, nothing)
    DuckDB.end_row(appender.techs)

    foreach(site -> store(appender, site, tech, region), tech.sites)

end

function store(
    appender::DataAppender,
    tech::ThermalCandidateParams,
    region::RegionParams)

    DuckDB.append(appender.techs, tech.name)
    DuckDB.append(appender.techs, region.name)
    DuckDB.append(appender.techs, "thermal")
    DuckDB.append(appender.techs, tech.cost_generation / powerunits_MW)
    DuckDB.append(appender.techs, tech.cost_capital / powerunits_MW)
    DuckDB.append(appender.techs, nothing)
    DuckDB.end_row(appender.techs)

    DuckDB.append(appender.sites, "")
    DuckDB.append(appender.sites, tech.name)
    DuckDB.append(appender.sites, region.name)
    DuckDB.end_row(appender.sites)

end

function store(appender::DataAppender, stor::StorageExistingParams, region::RegionParams)

    DuckDB.append(appender.techs, stor.name)
    DuckDB.append(appender.techs, region.name)
    DuckDB.append(appender.techs, "storage")
    DuckDB.append(appender.techs, stor.cost_operation / powerunits_MW)
    DuckDB.append(appender.techs, nothing)
    DuckDB.append(appender.techs, nothing)
    DuckDB.end_row(appender.techs)

    foreach(site -> store(appender, site, stor, region), stor.sites)

end

function store(appender::DataAppender, stor::StorageCandidateParams, region::RegionParams)

    DuckDB.append(appender.techs, name(stor))
    DuckDB.append(appender.techs, name(region))
    DuckDB.append(appender.techs, "storage")
    DuckDB.append(appender.techs, stor.cost_operation / powerunits_MW)
    DuckDB.append(appender.techs, stor.cost_capital_power / powerunits_MW)
    DuckDB.append(appender.techs, nothing) # Energy costs are in power costs
    DuckDB.end_row(appender.techs)

    DuckDB.append(appender.sites, "")
    DuckDB.append(appender.sites, name(stor))
    DuckDB.append(appender.sites, name(region))
    DuckDB.end_row(appender.sites)

end

function store(appender::DataAppender, site::SiteParams,
               tech::TechnologyParams, region::RegionParams)

    DuckDB.append(appender.sites, name(site))
    DuckDB.append(appender.sites, name(tech))
    DuckDB.append(appender.sites, name(region))
    DuckDB.end_row(appender.sites)

end

function store(appender::DataAppender, iface::InterfaceParams, regions::Vector{RegionParams})

    region_from = regions[iface.region_from].name
    region_to = regions[iface.region_to].name

    DuckDB.append(appender.interfaces, region_from)
    DuckDB.append(appender.interfaces, region_to)
    DuckDB.append(appender.interfaces, iface.cost_capital / powerunits_MW)
    DuckDB.end_row(appender.interfaces)

end

function store_iteration(con::DuckDB.DB, iter::Int)
    DBInterface.execute(con, "INSERT into iterations (id) VALUES (?)", (iter,))
end

function store_iteration_step(
    con::DuckDB.DB, iter::Int, step::String,
    times::Pair{DateTime,DateTime})

    DBInterface.execute(
        con,
        "INSERT into iteration_steps (
            iteration, step, t_start, t_end
        ) VALUES (?, ?, ?, ?)",
        (iter, step, first(times), last(times))
    )

end
