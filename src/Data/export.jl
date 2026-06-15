import DBInterface
import DuckDB

import ..store, ..powerunits_MW

struct DataAppender

    techs::DuckDB.Appender
    sites::DuckDB.Appender

    DataAppender(con::DuckDB.DB) = new(
        DuckDB.Appender(con, "techs"),
        DuckDB.Appender(con, "sites"),
    )

end

function DuckDB.close(appender::DataAppender)
    DuckDB.close(appender.techs)
    DuckDB.close(appender.sites)
    return
end

function store(con::DuckDB.DB, sys::SystemParams)

    DBInterface.execute(con, "CREATE TABLE techtypes (
        techtype TEXT PRIMARY KEY
    )")

    DBInterface.execute(con, "INSERT INTO techtypes VALUES
        ('thermal'),
        ('variable'),
        ('storage')")

    DBInterface.execute(con, "CREATE TABLE techs (
        tech TEXT,
        techtype TEXT REFERENCES techtypes (techtype),
        cost_generation DOUBLE,
        cost_capital_power DOUBLE,
        cost_capital_energy DOUBLE,
        PRIMARY KEY (tech)
    )")

    DBInterface.execute(con, "CREATE TABLE sites (
        site TEXT,
        tech TEXT REFERENCES techs (tech),
        PRIMARY KEY (site, tech)
    )")

    appender = DataAppender(con)

    foreach(tech -> store(appender, tech), sys.thermaltechs_existing)
    foreach(tech -> store(appender, tech), sys.thermaltechs_candidate)

    foreach(tech -> store(appender, tech), sys.variabletechs_existing)
    foreach(tech -> store(appender, tech), sys.variabletechs_candidate)

    foreach(tech -> store(appender, tech), sys.storagetechs_existing)
    foreach(tech -> store(appender, tech), sys.storagetechs_candidate)

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

function store(
    appender::DataAppender,
    tech::VariableExistingParams)

    DuckDB.append(appender.techs, tech.name)
    DuckDB.append(appender.techs, "variable")
    DuckDB.append(appender.techs, tech.cost_generation / powerunits_MW)
    DuckDB.append(appender.techs, nothing)
    DuckDB.append(appender.techs, nothing)
    DuckDB.end_row(appender.techs)

    foreach(site -> store(appender, site, tech), tech.sites)

end

function store(
    appender::DataAppender,
    tech::VariableCandidateParams)

    DuckDB.append(appender.techs, tech.name)
    DuckDB.append(appender.techs, "variable")
    DuckDB.append(appender.techs, tech.cost_generation / powerunits_MW)
    DuckDB.append(appender.techs, tech.cost_capital / powerunits_MW)
    DuckDB.append(appender.techs, nothing)
    DuckDB.end_row(appender.techs)

    foreach(site -> store(appender, site, tech), tech.sites)

end

function store(
    appender::DataAppender,
    tech::ThermalExistingParams)

    DuckDB.append(appender.techs, tech.name)
    DuckDB.append(appender.techs, "thermal")
    DuckDB.append(appender.techs, tech.cost_generation / powerunits_MW)
    DuckDB.append(appender.techs, nothing)
    DuckDB.append(appender.techs, nothing)
    DuckDB.end_row(appender.techs)

    foreach(site -> store(appender, site, tech), tech.sites)

end

function store(
    appender::DataAppender,
    tech::ThermalCandidateParams)

    DuckDB.append(appender.techs, tech.name)
    DuckDB.append(appender.techs, "thermal")
    DuckDB.append(appender.techs, tech.cost_generation / powerunits_MW)
    DuckDB.append(appender.techs, tech.cost_capital / powerunits_MW)
    DuckDB.append(appender.techs, nothing)
    DuckDB.end_row(appender.techs)

    DuckDB.append(appender.sites, "")
    DuckDB.append(appender.sites, tech.name)
    DuckDB.end_row(appender.sites)

end

function store(appender::DataAppender, stor::StorageExistingParams)

    DuckDB.append(appender.techs, stor.name)
    DuckDB.append(appender.techs, "storage")
    DuckDB.append(appender.techs, stor.cost_operation / powerunits_MW)
    DuckDB.append(appender.techs, nothing)
    DuckDB.append(appender.techs, nothing)
    DuckDB.end_row(appender.techs)

    foreach(site -> store(appender, site, stor), stor.sites)

end

function store(appender::DataAppender, stor::StorageCandidateParams)

    DuckDB.append(appender.techs, name(stor))
    DuckDB.append(appender.techs, "storage")
    DuckDB.append(appender.techs, stor.cost_operation / powerunits_MW)
    DuckDB.append(appender.techs, stor.cost_capital_power / powerunits_MW)
    DuckDB.append(appender.techs, stor.cost_capital_energy / powerunits_MW)
    DuckDB.end_row(appender.techs)

    DuckDB.append(appender.sites, "")
    DuckDB.append(appender.sites, name(stor))
    DuckDB.end_row(appender.sites)

end

function store(appender::DataAppender, site::SiteParams, tech::TechnologyParams)

    DuckDB.append(appender.sites, name(site))
    DuckDB.append(appender.sites, name(tech))
    DuckDB.end_row(appender.sites)

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
