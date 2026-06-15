import DBInterface
import DuckDB
import Dates: DateTime

import ..store, ..powerunits_MW

# TODO: These should all live in IterationModel/exports.jl
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
    flows::DuckDB.Appender

    DispatchAppender(con::DuckDB.DB) = new(
        DuckDB.Appender(con, "periods"),
        DuckDB.Appender(con, "demands"),
        DuckDB.Appender(con, "dispatches"),
        DuckDB.Appender(con, "flows")
    )

end

function DuckDB.close(appender::DispatchAppender)
    DuckDB.close(appender.periods)
    DuckDB.close(appender.demands)
    DuckDB.close(appender.dispatches)
    DuckDB.close(appender.flows)
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
        region TEXT REFERENCES regions(region),
        load DOUBLE,
        FOREIGN KEY (iteration, period) REFERENCES periods (iteration, period),
        PRIMARY KEY (iteration, period, timestep, region)
    )")

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS dispatches (
        iteration INTEGER,
        period TEXT,
        timestep INTEGER,
        tech TEXT,
        region TEXT,
        dispatch DOUBLE,
        FOREIGN KEY (iteration, period) REFERENCES periods (iteration, period),
        FOREIGN KEY (tech, region) REFERENCES techs (tech, region),
        PRIMARY KEY (iteration, period, timestep, tech, region)
    )")

    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS flows (
        iteration INTEGER,
        period TEXT,
        timestep INTEGER,
        region_from TEXT,
        region_to TEXT,
        flow DOUBLE,
        FOREIGN KEY (iteration, period) REFERENCES periods (iteration, period),
        FOREIGN KEY (region_from, region_to) REFERENCES interfaces (region_from, region_to),
        PRIMARY KEY (iteration, period, timestep, region_from, region_to)
    )")

    appender = DispatchAppender(con)

    store(appender, iter, seq.time)
    foreach(dispatch -> store(appender, iter, dispatch), seq.dispatches)

    DuckDB.close(appender)

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_generation AS
        SELECT iteration, period, tech, region, sum(dispatch) as generation from dispatches group by iteration, period, tech, region
    ")

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_generation_scaled AS
        SELECT iteration, period, tech, region, generation*reps as generation
        FROM summary_generation JOIN periods USING (iteration, period);
    ")

    DBInterface.execute(con, "CREATE VIEW IF NOT EXISTS summary_opex AS
        SELECT iteration, period, tech, region, cost_generation * generation AS opex
        FROM summary_generation_scaled JOIN techs USING (tech, region);
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

function store(appender::DispatchAppender, iter::Int, dispatch::SystemDispatch)

    foreach(region -> store(appender, iter, dispatch.period, region), dispatch.regions)

    foreach(interface ->
                store(appender, iter, dispatch.period, interface, dispatch.regions),
            dispatch.interfaces)

end

function store(
    appender::DispatchAppender, iter::Int, period::TimePeriod,
    region::RegionDispatch)

    for (i, t) in enumerate(period.timesteps)

        DuckDB.append(appender.demands, iter)
        DuckDB.append(appender.demands, period.name)
        DuckDB.append(appender.demands, i)
        DuckDB.append(appender.demands, name(region))
        DuckDB.append(appender.demands, demand(region, t) * powerunits_MW)
        DuckDB.end_row(appender.demands)

        for gen in region.thermaltechs

            dispatch = value(gen.dispatch[i]) * powerunits_MW

            DuckDB.append(appender.dispatches, iter)
            DuckDB.append(appender.dispatches, period.name)
            DuckDB.append(appender.dispatches, i)
            DuckDB.append(appender.dispatches, name(gen))
            DuckDB.append(appender.dispatches, name(region))
            DuckDB.append(appender.dispatches, dispatch)
            DuckDB.end_row(appender.dispatches)

        end

        for gen in region.variabletechs

            dispatch = value(gen.dispatch[i]) * powerunits_MW

            DuckDB.append(appender.dispatches, iter)
            DuckDB.append(appender.dispatches, period.name)
            DuckDB.append(appender.dispatches, i)
            DuckDB.append(appender.dispatches, name(gen))
            DuckDB.append(appender.dispatches, name(region))
            DuckDB.append(appender.dispatches, dispatch)
            DuckDB.end_row(appender.dispatches)

        end


        for stor in region.storagetechs

            dispatch = value(stor.dispatch[i]) * powerunits_MW

            DuckDB.append(appender.dispatches, iter)
            DuckDB.append(appender.dispatches, period.name)
            DuckDB.append(appender.dispatches, i)
            DuckDB.append(appender.dispatches, name(stor))
            DuckDB.append(appender.dispatches, name(region))
            DuckDB.append(appender.dispatches, dispatch)
            DuckDB.end_row(appender.dispatches)

        end

    end

end

function store(
    appender::DispatchAppender, iter::Int, period::TimePeriod,
    interface::InterfaceDispatch, regions::Vector{<:RegionDispatch})

    r_from = name(regions[region_from(interface)])
    r_to = name(regions[region_to(interface)])

    for (i, t) in enumerate(period.timesteps)

        flow = value(interface.flow[i]) * powerunits_MW

        DuckDB.append(appender.flows, iter)
        DuckDB.append(appender.flows, period.name)
        DuckDB.append(appender.flows, i)
        DuckDB.append(appender.flows, r_from)
        DuckDB.append(appender.flows, r_to)
        DuckDB.append(appender.flows, flow)
        DuckDB.end_row(appender.flows)

    end

end
