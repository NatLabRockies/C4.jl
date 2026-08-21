module IterationModel

using C4.Data
using C4.AdequacyModel
using C4.DispatchModel
using C4.ExpansionModel

import ..store, ..powerunits_MW
import C4.ExpansionModel: EUECuttingPlaneParams, ELCCCuttingPlaneParams

import Dates: Date, now
import DBInterface
import DelimitedFiles: writedlm
import DuckDB
import JuMP: value

export iterate_neue, sweep_iterate_neue, sweep_iterate_elcc

include("iterate_neue.jl")
include("iterate_elcc.jl")

function add_stressperiod(
    sys::SystemParams, invyear::Int,
    times::DispatchProxyMappings, adequacy::AdequacyResult;
    skip_existing::Bool=false
)

    # Don't bother adding a stress period if there's no unserved energy
    adequacy.eue[invyear] < 1e-4 && return times

    # TODO: Investigate using adequacy.generation_dEUEs (or both)?
    day_eues = vec(sum(adequacy.eues[:, :, invyear], dims=1))
    og_new_day_idx = argmax(day_eues)

    new_day_idx = og_new_day_idx

    while already_included(new_day_idx, times.days)

        skip_existing && return times

        new_day_idx = new_day_idx > 1 ? new_day_idx - 1 : length(day_eues)

        if new_day_idx == og_new_day_idx
            @warn("No unmodeled stress periods left to add")
            return times
        end

    end

    year, dayofyear = year_dayofyear(new_day_idx, sys.times)
    name = "Y$year D$dayofyear"
    new_day = DispatchDay(name, new_day_idx, sys.times)
    println("Adding period: $name")

    new_days = [times.days; new_day]

    new_mappings = deepcopy(times.mappings)

    dy, ddoy = year_dayofyear(new_day_idx, sys.times)
    new_mappings[dy].mapping[ddoy] = length(new_days)

    return DispatchProxyMappings(new_days, new_mappings)

end

already_included(day_idx::Int, days::Vector{DispatchDay}) =
    any(d -> d.dispatchday_idx == day_idx, days)

end
