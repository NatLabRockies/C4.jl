import DBInterface
import DuckDB

import ..store, ..powerunits_MW

struct DataAppender

    invyears::DuckDB.Appender
    techs::DuckDB.Appender
    tech_costs::DuckDB.Appender
    sites::DuckDB.Appender

    DataAppender(con::DuckDB.DB) = new(
        DuckDB.Appender(con, "investment_years"),
        DuckDB.Appender(con, "techs"),
        DuckDB.Appender(con, "tech_costs"),
        DuckDB.Appender(con, "sites"),
    )

end

function DuckDB.close(appender::DataAppender)
    DuckDB.close(appender.invyears)
    DuckDB.close(appender.techs)
    DuckDB.close(appender.tech_costs)
    DuckDB.close(appender.sites)
    return
end

function store(con::DuckDB.DB, sys::SystemParams)

    DBInterface.execute(con, "CREATE TABLE investment_years (
        year INTEGER PRIMARY KEY
    )")

    DBInterface.execute(con, "CREATE TABLE techtypes (
        techtype TEXT PRIMARY KEY
    )")

    DBInterface.execute(con, "INSERT INTO techtypes VALUES
        ('thermal'),
        ('variable'),
        ('storage')")

    DBInterface.execute(con, "CREATE TABLE techs (
        tech TEXT PRIMARY KEY,
        category TEXT,
        techtype TEXT REFERENCES techtypes (techtype)
    )")

    DBInterface.execute(con, "CREATE TABLE tech_costs (
        tech TEXT REFERENCES techs (tech),
        year INTEGER REFERENCES investment_years (year),
        cost_startup DOUBLE,
        cost_generation DOUBLE,
        cost_capital_power DOUBLE,
        cost_capital_energy DOUBLE,
        PRIMARY KEY (year, tech)
    )")

    DBInterface.execute(con, "CREATE TABLE sites (
        site TEXT,
        tech TEXT REFERENCES techs (tech),
        PRIMARY KEY (site, tech)
    )")

    appender = DataAppender(con)

    store(appender, sys.times)

    foreach(tech -> store(appender, tech, sys.times), sys.thermaltechs_existing)
    foreach(tech -> store(appender, tech, sys.times), sys.thermaltechs_candidate)

    foreach(tech -> store(appender, tech, sys.times), sys.variabletechs_existing)
    foreach(tech -> store(appender, tech, sys.times), sys.variabletechs_candidate)

    foreach(tech -> store(appender, tech, sys.times), sys.storagetechs_existing)
    foreach(tech -> store(appender, tech, sys.times), sys.storagetechs_candidate)

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

function store(appender::DataAppender, times::TimeIndices)

    for year in times.investment_years
        DuckDB.append(appender.invyears, year)
        DuckDB.end_row(appender.invyears)
    end

end

function store(
    appender::DataAppender, tech::VariableExistingParams, times::TimeIndices)

    DuckDB.append(appender.techs, tech.name)
    DuckDB.append(appender.techs, tech.category)
    DuckDB.append(appender.techs, "variable")
    DuckDB.end_row(appender.techs)

    for (y, year) in enumerate(times.investment_years)
        DuckDB.append(appender.tech_costs, tech.name)
        DuckDB.append(appender.tech_costs, year)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.append(appender.tech_costs, tech.cost_vom[y] / powerunits_MW)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.end_row(appender.tech_costs)
    end

    foreach(site -> store(appender, site, tech), tech.sites)

end

function store(
    appender::DataAppender, tech::VariableCandidateParams, times::TimeIndices)

    DuckDB.append(appender.techs, tech.name)
    DuckDB.append(appender.techs, tech.category)
    DuckDB.append(appender.techs, "variable")
    DuckDB.end_row(appender.techs)

    for (y, year) in enumerate(times.investment_years)
        DuckDB.append(appender.tech_costs, tech.name)
        DuckDB.append(appender.tech_costs, year)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.append(appender.tech_costs, tech.cost_vom[y] / powerunits_MW)
        DuckDB.append(appender.tech_costs, tech.cost_capital[y] / powerunits_MW)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.end_row(appender.tech_costs)
    end

    foreach(site -> store(appender, site, tech), tech.sites)

end

function store(
    appender::DataAppender, tech::ThermalExistingParams, times::TimeIndices)

    DuckDB.append(appender.techs, tech.name)
    DuckDB.append(appender.techs, tech.category)
    DuckDB.append(appender.techs, "thermal")
    DuckDB.end_row(appender.techs)

    for (y, year) in enumerate(times.investment_years)
        DuckDB.append(appender.tech_costs, tech.name)
        DuckDB.append(appender.tech_costs, year)
        DuckDB.append(appender.tech_costs, cost_startup(tech, y) / powerunits_MW)
        DuckDB.append(appender.tech_costs, cost_generation(tech, y) / powerunits_MW)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.end_row(appender.tech_costs)
    end

    foreach(site -> store(appender, site, tech), tech.sites)

end

function store(
    appender::DataAppender, tech::ThermalCandidateParams, times::TimeIndices)

    DuckDB.append(appender.techs, tech.name)
    DuckDB.append(appender.techs, tech.category)
    DuckDB.append(appender.techs, "thermal")
    DuckDB.end_row(appender.techs)

    for (y, year) in enumerate(times.investment_years)
        DuckDB.append(appender.tech_costs, tech.name)
        DuckDB.append(appender.tech_costs, year)
        DuckDB.append(appender.tech_costs, cost_startup(tech, y) / powerunits_MW)
        DuckDB.append(appender.tech_costs, cost_generation(tech) / powerunits_MW)
        DuckDB.append(appender.tech_costs, tech.cost_capital[y] / powerunits_MW)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.end_row(appender.tech_costs)
    end

    DuckDB.append(appender.sites, "")
    DuckDB.append(appender.sites, tech.name)
    DuckDB.end_row(appender.sites)

end

function store(
    appender::DataAppender, stor::StorageExistingParams, times::TimeIndices)

    DuckDB.append(appender.techs, stor.name)
    DuckDB.append(appender.techs, stor.category)
    DuckDB.append(appender.techs, "storage")
    DuckDB.end_row(appender.techs)

    for (y, year) in enumerate(times.investment_years)
        DuckDB.append(appender.tech_costs, stor.name)
        DuckDB.append(appender.tech_costs, year)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.append(appender.tech_costs, stor.cost_vom[y] / powerunits_MW)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.end_row(appender.tech_costs)
    end

    foreach(site -> store(appender, site, stor), stor.sites)

end

function store(
    appender::DataAppender, stor::StorageCandidateParams, times::TimeIndices)

    DuckDB.append(appender.techs, stor.name)
    DuckDB.append(appender.techs, stor.category)
    DuckDB.append(appender.techs, "storage")
    DuckDB.end_row(appender.techs)

    for (y, year) in enumerate(times.investment_years)
        DuckDB.append(appender.tech_costs, stor.name)
        DuckDB.append(appender.tech_costs, year)
        DuckDB.append(appender.tech_costs, nothing)
        DuckDB.append(appender.tech_costs, stor.cost_vom[y] / powerunits_MW)
        DuckDB.append(appender.tech_costs, stor.cost_capital_power[y] / powerunits_MW)
        DuckDB.append(appender.tech_costs, stor.cost_capital_energy[y] / powerunits_MW)
        DuckDB.end_row(appender.tech_costs)
    end

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
