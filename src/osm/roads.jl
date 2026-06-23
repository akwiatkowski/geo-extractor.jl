# Road extraction from parsed OSM data.
#
# Extracts ways with highway=* tags as typed Road structs.

# Recognized highway types (ordered by importance)
const HIGHWAY_TYPES = Set([
    "motorway", "motorway_link", "trunk", "trunk_link",
    "primary", "primary_link", "secondary", "secondary_link",
    "tertiary", "tertiary_link", "residential", "unclassified",
    "living_street", "pedestrian", "service", "cycleway", "footway", "path",
    "track", "bridleway",
])

# One-way tag values that indicate true
const ONEWAY_VALUES = Set(["yes", "true", "1", "-1"])

"""
    extract_roads(data::OsmData) → Vector{Road}

Extract all roads from parsed OSM data.

Filters ways with recognized `highway=*` tags. Skips ways with fewer
than 2 resolved nodes.

# Examples
```julia
data = parse_osm_xml("town.osm")
roads = extract_roads(data)
```
"""
function extract_roads(data::OsmData)::Vector{Road}
    roads = Road[]
    for (id, way) in data.ways
        highway = get(way.tags, "highway", "")
        isempty(highway) && continue
        highway in HIGHWAY_TYPES || continue

        coords = resolve_way_coords(way, data.nodes)
        length(coords) < 2 && continue

        name = get(way.tags, "name", "")
        oneway = get(way.tags, "oneway", "") in ONEWAY_VALUES
        lanes = _parse_lanes(way.tags)

        push!(roads, Road(id, highway, coords, name, oneway, lanes))
    end

    return roads
end

function _parse_lanes(tags::Dict{String,String})::Int
    lanes_str = get(tags, "lanes", "")
    isempty(lanes_str) && return 0
    v = tryparse(Int, lanes_str)
    return v === nothing ? 0 : v
end
