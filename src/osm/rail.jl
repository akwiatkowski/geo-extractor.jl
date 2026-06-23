# Rail infrastructure extraction from parsed OSM data.
#
# Extracts railway stations/halts (nodes) and track segments (ways).

# Rail type mapping from OSM railway tag
const RAIL_TYPE_MAP = Dict{String, Symbol}(
    "rail"          => :rail,
    "narrow_gauge"  => :narrow_gauge,
    "tram"          => :tram,
    "light_rail"    => :rail,
)

# Electrification tag values that indicate true
const ELECTRIFIED_VALUES = Set(["yes", "contact_line", "rail", "4th_rail"])

"""
    extract_rail_stations(data::OsmData) → Vector{RailStation}

Extract railway stations and halts from parsed OSM data.

Looks for nodes with `railway=station` or `railway=halt` tags.

# Examples
```julia
data = parse_osm_xml("town.osm")
stations = extract_rail_stations(data)
```
"""
function extract_rail_stations(data::OsmData)::Vector{RailStation}
    stations = RailStation[]

    for (id, node) in data.nodes
        railway = get(node.tags, "railway", "")
        (railway == "station" || railway == "halt") || continue

        name = get(node.tags, "name", "")
        operator = get(node.tags, "operator", "")
        is_halt = railway == "halt"

        push!(stations, RailStation(id, name, node.coord, is_halt, operator))
    end

    return stations
end

"""
    extract_rail_segments(data::OsmData) → Vector{RailSegment}

Extract railway track segments from parsed OSM data.

Looks for ways with `railway=rail`, `railway=narrow_gauge`, `railway=tram`,
or `railway=light_rail` tags.

# Examples
```julia
data = parse_osm_xml("town.osm")
segments = extract_rail_segments(data)
```
"""
function extract_rail_segments(data::OsmData)::Vector{RailSegment}
    segments = RailSegment[]

    for (id, way) in data.ways
        railway = get(way.tags, "railway", "")
        rail_type = get(RAIL_TYPE_MAP, railway, nothing)
        rail_type === nothing && continue

        coords = resolve_way_coords(way, data.nodes)
        length(coords) < 2 && continue

        electrified = get(way.tags, "electrified", "") in ELECTRIFIED_VALUES
        gauge = _parse_int_tag(way.tags, "gauge", 1435)
        maxspeed = _parse_int_tag(way.tags, "maxspeed", 0)

        push!(segments, RailSegment(id, rail_type, coords, electrified, gauge, maxspeed))
    end

    return segments
end

function _parse_int_tag(tags::Dict{String,String}, key::String, default::Int)::Int
    v = get(tags, key, "")
    isempty(v) && return default
    parsed = tryparse(Int, v)
    return parsed === nothing ? default : parsed
end
