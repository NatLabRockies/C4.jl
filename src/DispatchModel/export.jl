import DBInterface
import DuckDB
import Dates: DateTime

import ..store, ..powerunits_MW

"""
Standalone DispatchProblem persistence (not invoked by IterationModel)
"""
function store(
    con::DBInterface.Connection, pcm::DispatchProblem,
    timings::Pair{DateTime,DateTime}; iter::Int=0)

    store(con, pcm.system)
    store_iteration(con, iter)
    store_iteration_step(con, iter, "dispatch", timings)
    store(con, iter, pcm.invyear, pcm.dispatch, pcm.system.times)

end

struct DispatchAppender

    periods::DuckDB.Appender
    demands::DuckDB.Appender
    dispatches::DuckDB.Appender

    DispatchAppender(con::DuckDB.DB) = new(
        DuckDB.Appender(con, "periods"),
        DuckDB.Appender(con, "demands"),
        DuckDB.Appender(con, "dispatches")
    )

end

function DuckDB.close(appender::DispatchAppender)
    DuckDB.close(appender.periods)
    DuckDB.close(appender.demands)
    DuckDB.close(appender.dispatches)
    return
end

function store(con::DBInterface.Connection, iter::Int, i::Int, seq::DispatchSequence,
               sys_times::TimeIndices) # TODO: More elegant way of passing this in?

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS periods (
        iteration INTEGER REFERENCES iterations(id),
        year INTEGER REFERENCES investment_years (year),
        period TEXT,
        dispyear INTEGER,
        dayofyear INTEGER,
        reps INTEGER,
        PRIMARY KEY (iteration, year, period)
    )")

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS demands (
        iteration INTEGER,
        year INTEGER,
        period TEXT,
        timestep INTEGER,
        load DOUBLE,
        FOREIGN KEY (iteration, year, period)
            REFERENCES periods (iteration, year, period),
        PRIMARY KEY (iteration, year, period, timestep)
    )")

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS dispatches (
        iteration INTEGER,
        year INTEGER,
        period TEXT,
        timestep INTEGER,
        tech TEXT,
        dispatch DOUBLE,
        FOREIGN KEY (iteration, year, period)
            REFERENCES periods (iteration, year, period),
        FOREIGN KEY (tech) REFERENCES techs (tech),
        PRIMARY KEY (iteration, year, period, timestep, tech)
    )")

    appender = DispatchAppender(con)

    store(appender, iter, i, seq.time, sys_times)
    foreach(dispatch -> store(appender, iter, i, dispatch, sys_times), seq.dispatches)

    DuckDB.close(appender)

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_generation AS
        SELECT iteration, year, period, tech, sum(dispatch) AS generation
        FROM dispatches GROUP BY iteration, year, period, tech
    ")

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_generation_abs AS
        SELECT iteration, year, period, tech, sum(abs(dispatch)) AS generation
        FROM dispatches GROUP BY iteration, year, period, tech
    ")

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_generation_scaled AS
        SELECT iteration, year, period, tech, generation*reps AS generation
        FROM summary_generation JOIN periods USING (iteration, year, period);
    ")

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_generation_scaled_abs AS
        SELECT iteration, year, period, tech, generation*reps AS generation
        FROM summary_generation_abs JOIN periods USING (iteration, year, period);
    ")

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_opex AS
        SELECT iteration, year, period, tech, cost_generation * generation AS opex
        FROM summary_generation_scaled_abs
        JOIN techs USING (tech)
        JOIN tech_costs using (year, tech);
    ")

end

function store(appender::DispatchAppender, iter::Int, i::Int,
               time::DispatchProxyMapping, times::TimeIndices)

    reps = zeros(Int, length(time.days))
    foreach(p_idx -> reps[p_idx] += 1, time.mapping)
    foreach((p, n) -> store(appender, iter, i, p, n, times), time.days, reps)

end

function store(appender::DispatchAppender, iter::Int, i::Int,
               period::DispatchDay, reps::Int, times::TimeIndices)

    DuckDB.append(appender.periods, iter)
    DuckDB.append(appender.periods, times.investment_years[i])
    DuckDB.append(appender.periods, period.name)
    DuckDB.append(appender.periods, period.dispatchyear_idx)
    DuckDB.append(appender.periods, period.dispatchdayofyear_idx)
    DuckDB.append(appender.periods, reps)
    DuckDB.end_row(appender.periods)

end

function store(appender::DispatchAppender, iter::Int, i::Int,
               dispatch::SystemDispatch, times::TimeIndices)

    invyear = times.investment_years[i]
    d = dispatch.period.dispatchday_idx

    for h in 1:N_HOURS_IN_DAY

        DuckDB.append(appender.demands, iter)
        DuckDB.append(appender.demands, invyear)
        DuckDB.append(appender.demands, dispatch.period.name)
        DuckDB.append(appender.demands, h)
        DuckDB.append(appender.demands, demand(dispatch.system, i, d, h) * powerunits_MW)
        DuckDB.end_row(appender.demands)

        for gen in dispatch.thermaltechs

            dispatch_val = value(gen.dispatch[h]) * powerunits_MW

            DuckDB.append(appender.dispatches, iter)
            DuckDB.append(appender.dispatches, invyear)
            DuckDB.append(appender.dispatches, dispatch.period.name)
            DuckDB.append(appender.dispatches, h)
            DuckDB.append(appender.dispatches, name(gen))
            DuckDB.append(appender.dispatches, dispatch_val)
            DuckDB.end_row(appender.dispatches)

        end

        for gen in dispatch.variabletechs

            dispatch_val = value(gen.dispatch[h]) * powerunits_MW

            DuckDB.append(appender.dispatches, iter)
            DuckDB.append(appender.dispatches, invyear)
            DuckDB.append(appender.dispatches, dispatch.period.name)
            DuckDB.append(appender.dispatches, h)
            DuckDB.append(appender.dispatches, name(gen))
            DuckDB.append(appender.dispatches, dispatch_val)
            DuckDB.end_row(appender.dispatches)

        end

        for stor in dispatch.storagetechs

            dispatch_val = value(stor.dispatch[h]) * powerunits_MW

            DuckDB.append(appender.dispatches, iter)
            DuckDB.append(appender.dispatches, invyear)
            DuckDB.append(appender.dispatches, dispatch.period.name)
            DuckDB.append(appender.dispatches, h)
            DuckDB.append(appender.dispatches, name(stor))
            DuckDB.append(appender.dispatches, dispatch_val)
            DuckDB.end_row(appender.dispatches)

        end

    end

end
