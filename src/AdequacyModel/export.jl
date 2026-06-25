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
        iteration INTEGER REFERENCES iterations (id),
        year INTEGER REFERENCES investment_years (year),
        demand DOUBLE,
        eue DOUBLE,
        eue_std DOUBLE,
        lole DOUBLE,
        lole_std DOUBLE,
        PRIMARY KEY (iteration, year)
    )")

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS timestep_adequacies (
        iteration INTEGER REFERENCES iterations (id),
        year INTEGER REFERENCES investment_years (year),
        dispyear INTEGER,
        dayofyear INTEGER,
        hourofday INTEGER,
        demand DOUBLE,
        eue DOUBLE,
        eue_std DOUBLE,
        lole DOUBLE,
        lole_std DOUBLE,
        PRIMARY KEY (iteration, year, dispyear, dayofyear, hourofday)
    )")

    appender = AdequacyAppender(con)
    invyear = first(result.times.investment_years)

    demand = sum(result.demand)
    eue = sum(result.eues)
    lole = sum(result.lolps)

    DuckDB.append(appender.adequacies, iter)
    DuckDB.append(appender.adequacies, invyear)
    DuckDB.append(appender.adequacies, demand)
    DuckDB.append(appender.adequacies, eue)
    DuckDB.append(appender.adequacies, nothing)
    DuckDB.append(appender.adequacies, lole)
    DuckDB.append(appender.adequacies, nothing)
    DuckDB.end_row(appender.adequacies)

    for (d, (year, dayofyear)) in enumerate(days(result.times))
        for hourofday in 1:N_HOURS_IN_DAY

            DuckDB.append(appender.timestep_adequacies, iter)
            DuckDB.append(appender.timestep_adequacies, invyear)
            DuckDB.append(appender.timestep_adequacies, year)
            DuckDB.append(appender.timestep_adequacies, dayofyear)
            DuckDB.append(appender.timestep_adequacies, hourofday)
            DuckDB.append(appender.timestep_adequacies, result.demand[hourofday, d])
            DuckDB.append(appender.timestep_adequacies, result.eues[hourofday, d])
            DuckDB.append(appender.timestep_adequacies, nothing)
            DuckDB.append(appender.timestep_adequacies, result.lolps[hourofday, d])
            DuckDB.append(appender.timestep_adequacies, nothing)
            DuckDB.end_row(appender.timestep_adequacies)

        end
    end

    DuckDB.close(appender)

    return

end
