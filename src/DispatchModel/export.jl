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
    store(con, iter, pcm.dispatch)

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

function store(con::DBInterface.Connection, iter::Int, seq::DispatchSequence)

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS periods (
        iteration INTEGER REFERENCES iterations(id),
        period TEXT,
        reps INTEGER,
        t_start INTEGER,
        t_end INTEGER,
        PRIMARY KEY (iteration, period)
    )")

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS demands (
        iteration INTEGER,
        period TEXT,
        timestep INTEGER,
        load DOUBLE,
        FOREIGN KEY (iteration, period) REFERENCES periods (iteration, period),
        PRIMARY KEY (iteration, period, timestep)
    )")

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS dispatches (
        iteration INTEGER,
        period TEXT,
        timestep INTEGER,
        tech TEXT,
        dispatch DOUBLE,
        FOREIGN KEY (iteration, period) REFERENCES periods (iteration, period),
        FOREIGN KEY (tech) REFERENCES techs (tech),
        PRIMARY KEY (iteration, period, timestep, tech)
    )")

    appender = DispatchAppender(con)

    store(appender, iter, seq.time)
    foreach(dispatch -> store(appender, iter, dispatch), seq.dispatches)

    DuckDB.close(appender)

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_generation AS
        SELECT iteration, period, tech, sum(dispatch) AS generation
        FROM dispatches GROUP BY iteration, period, tech
    ")

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_generation_scaled AS
        SELECT iteration, period, tech, generation*reps AS generation
        FROM summary_generation JOIN periods USING (iteration, period);
    ")

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_opex AS
        SELECT iteration, period, tech, cost_generation * generation AS opex
        FROM summary_generation_scaled JOIN techs USING (tech);
    ")

end

function store(appender::DispatchAppender, iter::Int, time::TimeProxyAssignment)
    reps = zeros(Int, length(time.periods))
    foreach(p_idx -> reps[p_idx] += 1, time.days)
    foreach((p, n) -> store(appender, iter, p, n), time.periods, reps)
end

function store(appender::DispatchAppender, iter::Int, period::TimePeriod, reps::Int)

    DuckDB.append(appender.periods, iter)
    DuckDB.append(appender.periods, period.name)
    DuckDB.append(appender.periods, reps)
    DuckDB.append(appender.periods, first(period.timesteps))
    DuckDB.append(appender.periods, last(period.timesteps))
    DuckDB.end_row(appender.periods)

end

function store(appender::DispatchAppender, iter::Int, system::SystemDispatch)

    for (i, t) in enumerate(system.period.timesteps)

        DuckDB.append(appender.demands, iter)
        DuckDB.append(appender.demands, system.period.name)
        DuckDB.append(appender.demands, i)
        DuckDB.append(appender.demands, demand(system, t) * powerunits_MW)
        DuckDB.end_row(appender.demands)

        for gen in system.thermaltechs

            dispatch = value(gen.dispatch[i]) * powerunits_MW

            DuckDB.append(appender.dispatches, iter)
            DuckDB.append(appender.dispatches, system.period.name)
            DuckDB.append(appender.dispatches, i)
            DuckDB.append(appender.dispatches, name(gen))
            DuckDB.append(appender.dispatches, dispatch)
            DuckDB.end_row(appender.dispatches)

        end

        for gen in system.variabletechs

            dispatch = value(gen.dispatch[i]) * powerunits_MW

            DuckDB.append(appender.dispatches, iter)
            DuckDB.append(appender.dispatches, system.period.name)
            DuckDB.append(appender.dispatches, i)
            DuckDB.append(appender.dispatches, name(gen))
            DuckDB.append(appender.dispatches, dispatch)
            DuckDB.end_row(appender.dispatches)

        end

        for stor in system.storagetechs

            dispatch = value(stor.dispatch[i]) * powerunits_MW

            DuckDB.append(appender.dispatches, iter)
            DuckDB.append(appender.dispatches, system.period.name)
            DuckDB.append(appender.dispatches, i)
            DuckDB.append(appender.dispatches, name(stor))
            DuckDB.append(appender.dispatches, dispatch)
            DuckDB.end_row(appender.dispatches)

        end

    end

end
