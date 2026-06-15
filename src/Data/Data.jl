module Data

using Dates, DelimitedFiles

import Base: length

import ..VariableSite, ..Technology,
       ..ThermalTechnology, ..VariableTechnology, ..StorageTechnology,
       ..System, ..cost_generation,
       ..maxpower, ..maxenergy, ..roundtrip_efficiency, ..operating_cost,
       ..name, ..variabletechs, ..storagetechs, ..thermaltechs,
       ..sites, ..availability, ..nameplatecapacity, ..availablecapacity,
       ..demand, ..powerunits_MW

export TimePeriod, TimeProxyAssignment,
       ThermalExistingParams, ThermalExistingSiteParams, ThermalCandidateParams,
       VariableExistingParams, VariableExistingSiteParams,
       VariableCandidateParams, VariableCandidateSiteParams,
       StorageExistingParams, StorageExistingSiteParams, StorageCandidateParams,
       RegionParams, InterfaceParams, SystemParams,
       timestepcount, total_demand,
       singleperiod,
       seasonalperiods, monthlyperiods, weeklyperiods,
       seasonalperiods_byyear, monthlyperiods_byyear, weeklyperiods_byyear,
       dailyperiods, fullchronologyperiods,
       store_iteration, store_iteration_step

include("time.jl")

include("thermal.jl")
include("variable.jl")
include("storage.jl")

include("sites.jl")
include("technologies.jl")

include("system.jl")

include("representative_periods.jl")

include("import.jl")
include("export.jl")

end
