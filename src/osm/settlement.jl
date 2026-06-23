# Settlement lookup from parsed OSM data.
#
# Finds settlement nodes (place=city/town/village/hamlet) by name
# and extracts metadata.

# Valid place types for settlements
const PLACE_TYPES = Set(["city", "town", "village", "hamlet"])

# Polish character transliteration for slugs
const POLISH_TRANS = Dict(
    'ą' => "a", 'ć' => "c", 'ę' => "e", 'ł' => "l", 'ń' => "n",
    'ó' => "o", 'ś' => "s", 'ź' => "z", 'ż' => "z",
    'Ą' => "a", 'Ć' => "c", 'Ę' => "e", 'Ł' => "l", 'Ń' => "n",
    'Ó' => "o", 'Ś' => "s", 'Ź' => "z", 'Ż' => "z",
)

"""
    slugify(name::String) → String

Convert a name to an ASCII slug suitable for file paths.
Transliterates Polish characters, lowercases, replaces spaces with hyphens,
and strips non-alphanumeric characters.

# Examples
```jldoctest
julia> slugify("Pobiedziska")
"pobiedziska"

julia> slugify("Święta Anna")
"swieta-anna"
```
"""
function slugify(name::String)::String
    result = IOBuffer()
    for ch in name
        trans = get(POLISH_TRANS, ch, nothing)
        if trans !== nothing
            write(result, trans)
        elseif ch == ' ' || ch == '-'
            write(result, '-')
        elseif isletter(ch) || isdigit(ch)
            write(result, lowercase(ch))
        end
    end
    return String(take!(result))
end

"""
    find_settlements(data::OsmData) → Vector{Settlement}

Find all settlement nodes in parsed OSM data.

Looks for nodes with `place=city`, `place=town`, `place=village`, or `place=hamlet`.
Extracts name, population, and administrative hierarchy from tags.

# Examples
```julia
data = parse_osm_xml("town.osm")
settlements = find_settlements(data)
```
"""
function find_settlements(data::OsmData)::Vector{Settlement}
    settlements = Settlement[]

    for (_, node) in data.nodes
        place = get(node.tags, "place", "")
        place in PLACE_TYPES || continue

        name = get(node.tags, "name", "")
        isempty(name) && continue

        slug = slugify(name)
        place_type = Symbol(place)
        population = _parse_int_tag(node.tags, "population", 0)
        voivodeship = get(node.tags, "is_in:province", "")
        powiat = get(node.tags, "is_in:county", "")

        # Strip common prefixes from admin tags
        voivodeship = _strip_admin_prefix(voivodeship)
        powiat = _strip_admin_prefix(powiat)

        push!(settlements, Settlement(name, slug, place_type, node.coord,
                                       population, voivodeship, powiat))
    end

    return settlements
end

"""
    find_settlement(data::OsmData, name::String) → Union{Settlement, Nothing}

Find a settlement by name in parsed OSM data.

Performs case-insensitive search. Prefers towns over villages when
multiple matches exist.

# Examples
```julia
data = parse_osm_xml("town.osm")
s = find_settlement(data, "Testowo")
s.place_type  # :town
```
"""
function find_settlement(data::OsmData, name::String)::Union{Settlement,Nothing}
    settlements = find_settlements(data)
    name_lower = lowercase(name)

    matches = [s for s in settlements if lowercase(s.name) == name_lower]
    isempty(matches) && return nothing

    # Prefer larger place types
    type_priority = Dict(:city => 1, :town => 2, :village => 3, :hamlet => 4)
    sort!(matches, by=s -> get(type_priority, s.place_type, 99))
    return first(matches)
end

function _strip_admin_prefix(s::String)::String
    s = replace(s, "województwo " => "")
    s = replace(s, "powiat " => "")
    return strip(s)
end
