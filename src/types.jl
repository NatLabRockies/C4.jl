abstract type DispatchableSite end
abstract type DispatchableTech end

"""
`DispatchableVariableSite` is an abstract type that can be used to instantiate dispatch
problems. Instances of `DispatchableVariableSite` should define:

`nameplatecapacity(site::DispatchableVariableSite)`
Returns installed capacity in `C4.powerunits_MW`.

`availability(site::DispatchableVariableSite, i::Int, d::Int, h::Int) -> Float64`
Returns a unitless value between 0.0 and 1.0 corresponding to
the `h`-th hour of the `d`-th dispatch day of the `i`-th investment year.
"""
abstract type DispatchableVariableSite <: DispatchableSite end

function availability end
function nameplatecapacity end

availablecapacity(site::DispatchableVariableSite, invyear::Int, day::Int, hour::Int) =
    nameplatecapacity(site, invyear) * availability(site, invyear, day, hour)

"""
`DispatchableVariableTech` is an abstract type that can be used to instantiate
dispatch problems. Instances of `DispatchableVariableTech` should define:

`name(tech::DispatchableVariableTech) -> AbstractString`
Returns the technology name.

`sites(tech::DispatchableVariableTech) -> Vector{<:VariableSite}`
Returns a vector of the `VariableSite`s associated with the `VariableTech`.

`cost_generation(tech::DispatchableVariableTech, i::Int) -> Float64`
Returns the marginal generating cost of `tech` in the i-ith investment year,
in units of \$/C4.powerunits_MW.
"""
abstract type DispatchableVariableTech <: DispatchableTech end

function name end
function sites end
function cost_generation end

nameplatecapacity(tech::DispatchableVariableTech, invyear::Int) =
    sum(nameplatecapacity(site, invyear) for site in sites(tech); init=0)

availablecapacity(tech::DispatchableVariableTech, invyear::Int, day::Int, hour::Int) =
    sum(availablecapacity(site, invyear, day, hour) for site in sites(tech); init=0)

availablecapacity(tech::DispatchableVariableTech, t::Int) =
    sum(availablecapacity(site, 1,
        div(t-1, N_HOURS_IN_DAY)+1, rem(t-1, N_HOURS_IN_DAY)+1)
        for site in sites(tech); init=0)


"""
`DispatchableThermalTech` is an abstract type that can be used to instantiate
dispatch problems. Instances of `DispatchableThermalTech` should define:

`name(tech::DispatchableThermalTech) -> AbstractString`
Returns the technology name.

`nameplatecapacity(tech::DispatchableThermalTech, i::Int)`
Returns installed capacity in the `i`-th investment year,
in terms of `C4.powerunits_MW`.

`ratedcapacity(tech::DispatchableThermalTech, i::Int, d::Int, h::Int)`
Returns deterministically-derated (not including potential outages) capacity
in the `h`-th hour of the `d`-th dispatch day of the `i`-th investment year,
in terms of `C4.powerunits_MW`.

`expectedcapacity(tech::DispatchableThermalTech, i::Int, d::Int, h::Int)`
`Returns expected (average) available capacity (accounting for reliability
statistics) in the `h`-th hour of the `d`-th dispatch day of the
`i`-th investment year, in terms of `C4.powerunits_MW`.

`cost_generation(tech::DispatchableThermalTech, i::Int) -> Float64`
Returns the marginal generating cost of `tech` in the `i`-th investment year,
in units of \$/C4.powerunits_MW.

`max_unit_ramp(tech::DispatchableThermalTech) -> Float64`

`num_units(tech::DispatchableThermalTech, i::Int)`

`unit_size(tech::DispatchableThermalTech) -> Float64`

`min_gen(tech::DispatchableThermalTech) -> Float64`

`min_uptime(tech::DispatchableThermalTech) -> Float64`

`min_downtime(tech::DispatchableThermalTech) -> Float64`

`cost_startup(tech::DispatchableThermalTech, i::Int) -> Float64`

`co2_generation(tech::DispatchableThermalTech) -> Float64`

`co2_startup(tech::DispatchableThermalTech) -> Float64`
"""
abstract type DispatchableThermalTech <: DispatchableTech end
function max_unit_ramp end
function num_units end
function unit_size end
function min_gen end
function min_uptime end
function min_downtime end
function cost_startup end
function co2_startup end
function co2_generation end

"""
DispatchableStorageTech is an abstract type that can be used to instantiate
dispatch problems. Instances of DispatchableStorageTech should define:

```
maxpower(::DispatchableStorageTech)
maxenergy(::DispatchableStorageTech)
operating_cost(::DispatchableStorageTech) -> Float64
roundtrip_efficiency(::DispatchableStorageTech) -> Float64
```
"""
abstract type DispatchableStorageTech <: DispatchableTech end

function maxenergy end
function maxpower end
function operating_cost end
function roundtrip_efficiency end


function cost end
function cost_fom end
function co2 end
function co2_offset_cost end

function solve! end

function store end

"""
DispatchableSystem is an abstract type that can be used to instantiate
dispatch problems. Instances of System should define:
```
name(::DispatchableSystem)
demand(::DispatchableSystem, i::Int, d::Int, h::Int)
thermaltechs(::DispatchableSystem) -> Vector{DispatchableThermalTech}
variabletechs(::DispatchableSystem) -> Vector{DispatchableVariableTech}
storagetechs(::DispatchableSystem) -> Vector{DispatchableStorageTech}
```
"""
abstract type DispatchableSystem end

function demand end
function thermaltechs end
function variabletechs end
function storagetechs end
