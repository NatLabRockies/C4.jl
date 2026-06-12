import DBInterface
import DuckDB
import Dates: DateTime

import PRASCore: EUE, LOLE, val, stderror

import ..store, ..powerunits_MW

function store(
    con::DBInterface.Connection, result::AdequacyProblem,
    timings::Pair{DateTime,DateTime}; iter::Int=0)

    store(con, result.sys)
    store_iteration(con, iter)
    store_iteration_step(con, iter, "adequacy", timings)
    store(con, iter, result)

end

struct AdequacyAppender

    adequacies::DuckDB.Appender
    region_adequacies::DuckDB.Appender
    timestep_adequacies::DuckDB.Appender

    AdequacyAppender(con::DuckDB.DB) = new(
        DuckDB.Appender(con, "adequacies"),
        DuckDB.Appender(con, "region_adequacies"),
        DuckDB.Appender(con, "timestep_adequacies"),
    )

end

function DuckDB.close(appender::AdequacyAppender)
    DuckDB.close(appender.adequacies)
    DuckDB.close(appender.region_adequacies)
    DuckDB.close(appender.timestep_adequacies)
    return
end

function store(con::DBInterface.Connection, iter::Int, result::AdequacyResult)

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS adequacies (
        iteration INTEGER PRIMARY KEY REFERENCES iterations(id),
        demand DOUBLE,
        eue DOUBLE,
        eue_std DOUBLE,
        lole DOUBLE,
        lole_std DOUBLE
    )")

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS region_adequacies (
        iteration INTEGER REFERENCES iterations(id),
        region TEXT REFERENCES regions(region),
        demand DOUBLE,
        eue DOUBLE,
        eue_std DOUBLE,
        lole DOUBLE,
        lole_std DOUBLE,
        PRIMARY KEY (iteration, region)
    )")

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS timestep_adequacies (
        iteration INTEGER REFERENCES iterations(id),
        timestep TIMESTAMP,
        demand DOUBLE,
        eue DOUBLE,
        eue_std DOUBLE,
        lole DOUBLE,
        lole_std DOUBLE,
        PRIMARY KEY (iteration, timestep)
    )")

    appender = AdequacyAppender(con)

    region_names = result.shortfalls.regions.names
    region_demands = vec(sum(result.shortfalls.regions.load, dims=2))

    eue = EUE(result.shortfalls)
    lole = LOLE(result.shortfalls)

    DuckDB.append(appender.adequacies, iter)
    DuckDB.append(appender.adequacies, sum(region_demands))
    DuckDB.append(appender.adequacies, val(eue))
    DuckDB.append(appender.adequacies, stderror(eue))
    DuckDB.append(appender.adequacies, val(lole))
    DuckDB.append(appender.adequacies, stderror(lole))
    DuckDB.end_row(appender.adequacies)

    for (r, regionname) in enumerate(region_names)

        eue = EUE(result.shortfalls, regionname)
        lole = LOLE(result.shortfalls, regionname)

        DuckDB.append(appender.region_adequacies, iter)
        DuckDB.append(appender.region_adequacies, regionname)
        DuckDB.append(appender.region_adequacies, region_demands[r])
        DuckDB.append(appender.region_adequacies, val(eue))
        DuckDB.append(appender.region_adequacies, stderror(eue))
        DuckDB.append(appender.region_adequacies, val(lole))
        DuckDB.append(appender.region_adequacies, stderror(lole))
        DuckDB.end_row(appender.region_adequacies)

    end

    timestep_demands = vec(sum(result.shortfalls.regions.load, dims=1))

    for (t, timestamp) in enumerate(result.shortfalls.timestamps)

        eue = EUE(result.shortfalls, timestamp)
        lole = LOLE(result.shortfalls, timestamp)

        DuckDB.append(appender.timestep_adequacies, iter)
        DuckDB.append(appender.timestep_adequacies, DateTime(timestamp))
        DuckDB.append(appender.timestep_adequacies, timestep_demands[t])
        DuckDB.append(appender.timestep_adequacies, val(eue))
        DuckDB.append(appender.timestep_adequacies, stderror(eue))
        DuckDB.append(appender.timestep_adequacies, val(lole))
        DuckDB.append(appender.timestep_adequacies, stderror(lole))
        DuckDB.end_row(appender.timestep_adequacies)

    end

    DuckDB.close(appender)

    return

end
