abstract type Site end
abstract type Technology end

"""
`VariableSite` is an abstract type that can be used to instantiate dispatch
problems. Instances of `VariableSite` should define:

`nameplatecapacity(site::VariableSite)`
Returns installed capacity in `C4.powerunits_MW`.

`availability(site::VariableSite, t::Int) -> Float64`
Returns a unitless value between 0.0 and 1.0 corresponding to
global timestep `t`.
"""
abstract type VariableSite <: Site end

function availability end
function nameplatecapacity end

availablecapacity(site::VariableSite, t::Int) =
    nameplatecapacity(site) * availability(site, t)


"""
`VariableTechnology` is an abstract type that can be used to instantiate
dispatch problems. Instances of `VariableTechnology` should define:

`name(tech::VariableTechnology) -> AbstractString`
Returns the technology name.

`sites(tech::VariableTechnology) -> Vector{<:VariableSite}`
Returns a vector of the `VariableSite`s associated with the `VariableTechnology`.

`cost_generation(tech::VariableTechnology) -> Float64`
Returns the marginal generating cost of `tech` in units of \$/C4.powerunits_MW.
"""
abstract type VariableTechnology <: Technology end

function name end
function sites end
function cost_generation end

nameplatecapacity(tech::VariableTechnology) =
    sum(nameplatecapacity(site) for site in sites(tech); init=0)

availablecapacity(tech::VariableTechnology, t::Int) =
    sum(availablecapacity(site, t) for site in sites(tech); init=0)


"""
`ThermalTechnology` is an abstract type that can be used to instantiate
dispatch problems. Instances of `ThermalTechnology` should define:

`name(tech::ThermalTechnology) -> AbstractString`
Returns the technology name.

`nameplatecapacity(tech::ThermalTechnology)`
Returns installed capacity in `C4.powerunits_MW`.

`availablecapacity(tech::ThermalTechnology, t::Int)`
`Returns expected (average) available capacity in `C4.powerunits_MW`.

`cost_generation(tech::ThermalTechnology) -> Float64`
Returns the marginal generating cost of `tech` in units of \$/C4.powerunits_MW.

`max_unit_ramp(tech::ThermalTechnology) -> Float64`

`num_units(tech::ThermalTechnology)`

`unit_size(tech::ThermalTechnology) -> Float64`

`min_gen(tech::ThermalTechnology) -> Float64`
"""
abstract type ThermalTechnology <: Technology end
function max_unit_ramp end
function num_units end
function unit_size end
function min_gen end

"""
StorageTechnology is an abstract type that can be used to instantiate
dispatch problems. Instances of StorageTechnology should define:

```
maxpower(::StorageTechnology)
maxenergy(::StorageTechnology)
operating_cost(::StorageTechnology) -> Float64
roundtrip_efficiency(::StorageTechnology) -> Float64
```
"""
abstract type StorageTechnology <: Technology end

function maxenergy end
function maxpower end
function operating_cost end
function roundtrip_efficiency end


function cost end

function solve! end

function store end

"""
System is an abstract type that can be used to instantiate
dispatch problems. Instances of System should define:
```
name(::System)
demand(::System, t::Int)
thermaltechs(::System) -> Vector{ThermalTechnology}
variabletechs(::System) -> Vector{VariableTechnology}
storagetechs(::System) -> Vector{StorageTechnology}
```
"""
abstract type System end

function demand end
function thermaltechs end
function variabletechs end
function storagetechs end
