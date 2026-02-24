import DBInterface
import DuckDB
import Dates: DateTime

import ..store, ..powerunits_MW

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
    interfacebuilds::DuckDB.Appender

    ExpansionAppender(con::DuckDB.DB) = new(
        DuckDB.Appender(con, "sitebuilds"),
        DuckDB.Appender(con, "interfacebuilds")
    )

end

function DuckDB.close(appender::ExpansionAppender)
    DuckDB.close(appender.sitebuilds)
    DuckDB.close(appender.interfacebuilds)
    return
end

function store(con::DBInterface.Connection, iter::Int, sys::SystemExpansion)

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS sitebuilds (
        iteration INTEGER REFERENCES iterations(id),
        site TEXT,
        tech TEXT,
        region TEXT,
        power DOUBLE,
        energy DOUBLE,
        FOREIGN KEY (site, tech, region) REFERENCES sites (site, tech, region),
        PRIMARY KEY (iteration, site, tech, region)
    )")

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS interfacebuilds (
        iteration INTEGER REFERENCES iterations(id),
        region_from TEXT,
        region_to TEXT,
        capacity DOUBLE,
        FOREIGN KEY (region_from, region_to) REFERENCES interfaces (region_from, region_to),
        PRIMARY KEY (iteration, region_from, region_to)
    )")

    appender = ExpansionAppender(con)

    foreach(region -> store(appender, iter, region), sys.regions)
    foreach(iface -> store(appender, iter, iface, sys.regions), sys.interfaces)

    DuckDB.close(appender)

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_tech_capex AS
        SELECT iteration, site, tech, region, power * cost_capital_power as cost_power, energy * cost_capital_energy as cost_energy
        FROM sitebuilds JOIN techs USING (tech, region)
    ")

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_tx_capex AS
        SELECT iteration, region_from, region_to, capacity * cost_capital AS cost
        FROM interfacebuilds JOIN interfaces USING (region_from, region_to)
    ")

end

function store(appender::ExpansionAppender, iter::Int, region::RegionExpansion)

    foreach(tech -> store(appender, iter, tech, region), region.thermaltechs)
    foreach(tech -> store(appender, iter, tech, region), region.variabletechs)
    foreach(tech -> store(appender, iter, tech, region), region.storagetechs)

end

function store(appender::ExpansionAppender, iter::Int,
               tech::ThermalExpansion, region::RegionExpansion)

    new_capacity = value(tech.units_new) * tech.params.unit_size * powerunits_MW

    DuckDB.append(appender.sitebuilds, iter)
    DuckDB.append(appender.sitebuilds, "")
    DuckDB.append(appender.sitebuilds, name(tech))
    DuckDB.append(appender.sitebuilds, name(region))
    DuckDB.append(appender.sitebuilds, new_capacity)
    DuckDB.append(appender.sitebuilds, nothing)
    DuckDB.end_row(appender.sitebuilds)

end

store(appender::ExpansionAppender, iter::Int,
               tech::VariableExpansion, region::RegionExpansion) =
    foreach(site -> store(appender, iter, site, tech, region), tech.sites)

function store(appender::ExpansionAppender, iter::Int, site::VariableSiteExpansion,
               tech::VariableExpansion, region::RegionExpansion)

    new_capacity = value(site.capacity_new) * powerunits_MW

    DuckDB.append(appender.sitebuilds, iter)
    DuckDB.append(appender.sitebuilds, site.params.name)
    DuckDB.append(appender.sitebuilds, name(tech))
    DuckDB.append(appender.sitebuilds, name(region))
    DuckDB.append(appender.sitebuilds, new_capacity)
    DuckDB.append(appender.sitebuilds, nothing)
    DuckDB.end_row(appender.sitebuilds)

end

function store(appender::ExpansionAppender, iter::Int,
               tech::StorageExpansion, region::RegionExpansion)

    new_power = value(tech.power_new) * powerunits_MW
    new_energy = new_power * tech.params.duration

    DuckDB.append(appender.sitebuilds, iter)
    DuckDB.append(appender.sitebuilds, "")
    DuckDB.append(appender.sitebuilds, name(tech))
    DuckDB.append(appender.sitebuilds, name(region))
    DuckDB.append(appender.sitebuilds, new_power)
    DuckDB.append(appender.sitebuilds, new_energy)
    DuckDB.end_row(appender.sitebuilds)

end

function store(appender::ExpansionAppender, iter::Int,
               iface::InterfaceExpansion, regions::Vector{RegionExpansion})

    region_from = name(regions[iface.params.region_from])
    region_to = name(regions[iface.params.region_to])

    new_capacity = value(iface.capacity_new) * powerunits_MW

    DuckDB.append(appender.interfacebuilds, iter)
    DuckDB.append(appender.interfacebuilds, region_from)
    DuckDB.append(appender.interfacebuilds, region_to)
    DuckDB.append(appender.interfacebuilds, new_capacity)
    DuckDB.end_row(appender.interfacebuilds)

end
