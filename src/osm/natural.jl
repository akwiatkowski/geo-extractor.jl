# Natural feature extraction from parsed OSM data.
#
# Extracts water bodies, forests, parks, landuse zones from ways with
# natural=*, landuse=*, leisure=park tags.

# OSM tags that map to natural feature types
const NATURAL_FEATURE_TAGS = Dict{Tuple{String,String}, Symbol}(
    # Water
    ("natural", "water")          => :water,
    ("natural", "wetland")        => :wetland,
    ("natural", "beach")          => :beach,
    ("waterway", "river")         => :water,
    ("waterway", "stream")        => :water,
    ("waterway", "canal")         => :water,
    ("waterway", "ditch")         => :water,
    # Forest & woodland
    ("natural", "wood")           => :forest,
    ("landuse", "forest")         => :forest,
    # Grassland, meadow, scrub
    ("natural", "grassland")      => :grassland,
    ("natural", "scrub")          => :scrub,
    ("natural", "heath")          => :scrub,
    ("natural", "tree_row")       => :tree_row,
    ("landuse", "meadow")         => :meadow,
    ("landuse", "grass")          => :grassland,
    ("landuse", "village_green")  => :grassland,
    # Agriculture
    ("landuse", "farmland")       => :farmland,
    ("landuse", "farmyard")       => :farmyard,
    ("landuse", "orchard")        => :orchard,
    ("landuse", "vineyard")       => :orchard,
    ("landuse", "allotments")     => :allotments,
    # Built-up zones
    ("landuse", "residential")    => :residential,
    ("landuse", "commercial")     => :commercial,
    ("landuse", "industrial")     => :industrial,
    ("landuse", "retail")         => :commercial,
    ("landuse", "garages")        => :industrial,
    # Other
    ("landuse", "cemetery")       => :cemetery,
    ("leisure", "park")           => :park,
    ("leisure", "garden")         => :park,
    ("leisure", "nature_reserve") => :nature_reserve,
    ("leisure", "pitch")          => :pitch,
    ("leisure", "playground")     => :playground,
)

# Tags to check for natural features, in order
const NATURAL_TAG_KEYS = ["natural", "waterway", "landuse", "leisure"]

"""
    extract_natural_features(data::OsmData) → Vector{NaturalFeature}

Extract water bodies, forests, parks, and landuse zones from parsed OSM data.

Handles both closed ways (polygons) and open ways (linestrings, e.g. rivers).
Skips ways with fewer than 2 resolved nodes.

# Examples
```julia
data = parse_osm_xml("town.osm")
features = extract_natural_features(data)
```
"""
function extract_natural_features(data::OsmData)::Vector{NaturalFeature}
    features = NaturalFeature[]

    for (id, way) in data.ways
        feature_type = _classify_natural(way.tags)
        feature_type === nothing && continue

        coords = resolve_way_coords(way, data.nodes)
        length(coords) < 2 && continue

        name = get(way.tags, "name", "")

        # Determine geometry type: closed ring → polygon, open → linestring
        is_closed = length(coords) >= 3 && coords[1] ≈ coords[end]
        if is_closed
            # Remove closing vertex for clean ring
            ring = coords[1:end-1]
            push!(features, NaturalFeature(id, feature_type, :polygon, [ring], name))
        else
            push!(features, NaturalFeature(id, feature_type, :linestring, [coords], name))
        end
    end

    return features
end

function _classify_natural(tags::Dict{String,String})::Union{Symbol, Nothing}
    for key in NATURAL_TAG_KEYS
        value = get(tags, key, "")
        isempty(value) && continue
        ft = get(NATURAL_FEATURE_TAGS, (key, value), nothing)
        ft !== nothing && return ft
    end
    return nothing
end
