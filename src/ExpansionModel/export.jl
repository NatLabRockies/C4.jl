import DBInterface
import DuckDB
import Dates: DateTime

import ..store, ..powerunits_MW

"""
Standalone ExpansionProblem persistence (not invoked by IterationModel)
"""
function store(
    con::DBInterface.Connection, cem::ExpansionProblem,
    timings::Pair{DateTime,DateTime}; iter::Int=0)

    store(con, cem.system)
    store_iteration(con, iter)
    store_iteration_step(con, iter, "expansion", timings)
    store(con, iter, cem.builds)
    store(con, iter, cem.economicdispatch)

end

struct ExpansionAppender

    sitebuilds::DuckDB.Appender

    ExpansionAppender(con::DuckDB.DB) = new(
        DuckDB.Appender(con, "sitebuilds"),
    )

end

function DuckDB.close(appender::ExpansionAppender)
    DuckDB.close(appender.sitebuilds)
    return
end

function store(con::DBInterface.Connection, iter::Int, sys::SystemExpansion)

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS sitebuilds (
        iteration INTEGER REFERENCES iterations(id),
        site TEXT,
        tech TEXT,
        power DOUBLE,
        energy DOUBLE,
        FOREIGN KEY (site, tech) REFERENCES sites (site, tech),
        PRIMARY KEY (iteration, site, tech)
    )")

    appender = ExpansionAppender(con)

    foreach(tech -> store(appender, iter, tech), sys.thermaltechs)
    foreach(tech -> store(appender, iter, tech), sys.variabletechs)
    foreach(tech -> store(appender, iter, tech), sys.storagetechs)

    DuckDB.close(appender)

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_tech_capex AS
        SELECT iteration, site, tech,
            power * cost_capital_power as cost_power,
            energy * cost_capital_energy as cost_energy
        FROM sitebuilds JOIN techs USING (tech)
    ")

end

function store(appender::ExpansionAppender, iter::Int, tech::ThermalExpansion)

    new_capacity = value(tech.units_new) * tech.params.unit_size * powerunits_MW

    DuckDB.append(appender.sitebuilds, iter)
    DuckDB.append(appender.sitebuilds, "")
    DuckDB.append(appender.sitebuilds, name(tech))
    DuckDB.append(appender.sitebuilds, new_capacity)
    DuckDB.append(appender.sitebuilds, nothing)
    DuckDB.end_row(appender.sitebuilds)

end

store(appender::ExpansionAppender, iter::Int, tech::VariableExpansion) =
    foreach(site -> store(appender, iter, site, tech), tech.sites)

function store(appender::ExpansionAppender, iter::Int,
               site::VariableSiteExpansion, tech::VariableExpansion)

    new_capacity = value(site.capacity_new) * powerunits_MW

    DuckDB.append(appender.sitebuilds, iter)
    DuckDB.append(appender.sitebuilds, site.params.name)
    DuckDB.append(appender.sitebuilds, name(tech))
    DuckDB.append(appender.sitebuilds, new_capacity)
    DuckDB.append(appender.sitebuilds, nothing)
    DuckDB.end_row(appender.sitebuilds)

end

function store(appender::ExpansionAppender, iter::Int, tech::StorageExpansion)

    new_power = value(tech.power_new) * powerunits_MW
    new_energy = value(tech.energy_new) * powerunits_MW

    DuckDB.append(appender.sitebuilds, iter)
    DuckDB.append(appender.sitebuilds, "")
    DuckDB.append(appender.sitebuilds, name(tech))
    DuckDB.append(appender.sitebuilds, new_power)
    DuckDB.append(appender.sitebuilds, new_energy)
    DuckDB.end_row(appender.sitebuilds)

end
