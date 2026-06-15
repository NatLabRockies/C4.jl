import DBInterface
import DuckDB
import Dates: DateTime

import ..store, ..powerunits_MW

"""
Standalone AdequacyProblem persistence (not invoked by IterationModel)
"""
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
    timestep_adequacies::DuckDB.Appender

    AdequacyAppender(con::DuckDB.DB) = new(
        DuckDB.Appender(con, "adequacies"),
        DuckDB.Appender(con, "timestep_adequacies"),
    )

end

function DuckDB.close(appender::AdequacyAppender)
    DuckDB.close(appender.adequacies)
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

    demand = sum(result.demand)
    eue = sum(result.eues)
    lole = sum(result.lolps)

    DuckDB.append(appender.adequacies, iter)
    DuckDB.append(appender.adequacies, demand)
    DuckDB.append(appender.adequacies, eue)
    DuckDB.append(appender.adequacies, nothing)
    DuckDB.append(appender.adequacies, lole)
    DuckDB.append(appender.adequacies, nothing)
    DuckDB.end_row(appender.adequacies)

    for (t, timestamp) in enumerate(result.timestamps)

        DuckDB.append(appender.timestep_adequacies, iter)
        DuckDB.append(appender.timestep_adequacies, DateTime(timestamp))
        DuckDB.append(appender.timestep_adequacies, result.demand[t])
        DuckDB.append(appender.timestep_adequacies, result.eues[t])
        DuckDB.append(appender.timestep_adequacies, nothing)
        DuckDB.append(appender.timestep_adequacies, result.lolps[t])
        DuckDB.append(appender.timestep_adequacies, nothing)
        DuckDB.end_row(appender.timestep_adequacies)

    end

    DuckDB.close(appender)

    return

end
