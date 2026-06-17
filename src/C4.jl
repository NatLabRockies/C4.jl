module C4

# Internally represent power values in increments of 100MW.
# Helps with numerical stability in optimization solver
# Conversion to/from MW happens:
#  - when loading data from disk
#  - when formulating PRAS systems
#  - when converting PRAS results to risk curves
#    (slopes ok, but y-intercepts need correcting)
#  - when writing results to disk

const powerunits_MW = 100
const N_HOURS_IN_DAY = 24

include("types.jl")
include("jump_utils.jl")

include("Data/Data.jl")
include("AdequacyModel/AdequacyModel.jl")
include("DispatchModel/DispatchModel.jl")
include("ExpansionModel/ExpansionModel.jl")
include("IterationModel/IterationModel.jl")

end
