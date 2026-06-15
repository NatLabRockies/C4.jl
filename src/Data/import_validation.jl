# struct AddValidator{P,C}

#     parentname::String
#     parentset::Set{P}

#     childname::String
#     childsource::String
#     childset::Set{Tuple{P,C}}

#     AddValidator{C}(
#         parentname::String,
#         parentset::Set{P},
#         childname::String,
#         childsource::String,
#     ) where {P,C} = new{P,C}(
#         parentname, parentset,
#         childname, childsource, Set{Tuple{P,C}}())

# end

# function validate!(validator::AddValidator{P,C}, parent::P, child::C) where {P,C}

#     parent in validator.parentset ||
#         error("The $(validator.parentname) $(parent) " *
#               "in $(validator.childsource) does not exist in the system")

#     (parent, child) in validator.childset &&
#         error("The $(validator.childname) $(child) in " *
#               "$(validator.parentname) $(parent)" *
#               "is duplicated in $(validator.childsource)")

#     push!(validator.childset, (parent, child))

#     return

# end

# struct UpdateValidator{T}

#     elementname::String
#     localsource::String
#     localset::Set{T}
#     globalset::Set{T}

#     UpdateValidator(
#         elementname::String,
#         localsource::String,
#         globalset::Set{T}
#     ) where {T} = new{T}(elementname, localsource, Set{T}(), globalset)

# end

# function validate!(validator::UpdateValidator{T}, x::T) where T

#     x in validator.globalset ||
#         error("The $(validator.elementname) $(x) in " *
#               "$(validator.localsource) does not exist in the system")

#     x in validator.localset &&
#         error("The $(validator.elementname) $(x)" *
#               "is duplicated in $(validator.localsource)")

#     push!(validator.localset, x)

#     return

# end

function validate_columns(
    table::Matrix,
    cols_expected::Vector{<:AbstractString},
    filepath::AbstractString
)

    for (c, expected) in enumerate(cols_expected)

        actual = table[1, c]

        actual == expected || error(
            "Unexpected name for column $c in $filepath: " *
            "expected '$expected', got '$actual'")

    end

end
