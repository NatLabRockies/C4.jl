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
       SystemParams, total_demand, annualization_factor,
       year_dayofyear, days, n_investment_years, n_dispatch_years,
       n_dispatch_days, n_dispatch_hours, npv_opex, npv_capex,
       store_iteration, store_iteration_step

"""
Calculates the scaling factor to be applied to an overnight (principal) cost
to calculate the NPV (at the start of the loan) of the financed cost
(e.g., principal + interest) over `termlength` years.
`wacc` is used as both the borrowing rate (determining loan interest) and the
discount rate (determining NPV of future debt payments).
"""
function financing_factor(wacc::Float64, termlength::Int)
    a = (1+wacc)^termlength
    b = (1-wacc)^termlength)
    return a * (1 - b) / (a - 1)
end

include("time.jl")

include("thermal.jl")
include("variable.jl")
include("storage.jl")

include("system.jl")

include("import.jl")
include("export.jl")

end
