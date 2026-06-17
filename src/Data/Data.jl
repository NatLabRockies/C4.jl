module Data

using Dates, DelimitedFiles

import Base: length

import ..DispatchableVariableSite, ..DispatchableTech,
       ..DispatchableThermalTech, ..DispatchableVariableTech, ..DispatchableStorageTech,
       ..DispatchableSystem, ..cost_generation, ..cost_startup,
       ..maxpower, ..maxenergy, ..roundtrip_efficiency, ..operating_cost,
       ..max_unit_ramp, ..num_units, ..unit_size, ..min_gen, ..min_uptime, ..min_downtime,
       ..co2_startup, ..co2_generation,
       ..name, ..variabletechs, ..storagetechs, ..thermaltechs,
       ..sites, ..availability, ..nameplatecapacity, ..availablecapacity,
       ..demand, ..powerunits_MW, ..N_HOURS_IN_DAY

export TimeIndices,
       ThermalExistingParams, ThermalExistingSiteParams, ThermalCandidateParams,
       VariableExistingParams, VariableExistingSiteParams,
       VariableCandidateParams, VariableCandidateSiteParams,
       StorageExistingParams, StorageExistingSiteParams, StorageCandidateParams,
       SystemParams, total_demand,
       year_dayofyear, days, n_investment_years, n_dispatch_years,
       n_dispatch_days, n_dispatch_hours,
       store_iteration, store_iteration_step

include("time.jl")

include("thermal.jl")
include("variable.jl")
include("storage.jl")

include("system.jl")

include("import.jl")
include("export.jl")

end
