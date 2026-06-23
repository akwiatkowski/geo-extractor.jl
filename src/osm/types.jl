# Output types for OSM data extraction.
#
# All geographic fields use Coord from the Geo module.
# Polygons are Vector{Coord} with vertices in ring order.
# These types are the shared currency between OSM parsing and consumers
# (rendering, simulation, analysis).

# ── BuildingType enum ────────────────────────────────────────────────

"""
    BuildingType

Classification of buildings by primary function.
Matches common OSM building/amenity tag categories.

Values: `RESIDENTIAL_HOUSE`, `RESIDENTIAL_APARTMENT`, `COMMERCIAL_SHOP`,
`COMMERCIAL_OFFICE`, `INDUSTRIAL`, `EDUCATION`, `HEALTHCARE`, `PUBLIC`,
`RELIGIOUS`, `OTHER`
"""
@enum BuildingType begin
    RESIDENTIAL_HOUSE       # 0 — detached, semi-detached, terrace, farm
    RESIDENTIAL_APARTMENT   # 1 — apartments, dormitory, multi-story residential
    COMMERCIAL_SHOP         # 2 — retail, restaurant, cafe, supermarket
    COMMERCIAL_OFFICE       # 3 — office buildings
    INDUSTRIAL              # 4 — warehouse, factory, workshop
    EDUCATION               # 5 — school, university, kindergarten
    HEALTHCARE              # 6 — hospital, clinic, pharmacy
    PUBLIC                  # 7 — townhall, fire station, post office
    RELIGIOUS               # 8 — church, mosque, chapel
    OTHER                   # 9 — unclassified or unknown
end

# ── Building ─────────────────────────────────────────────────────────

"""
    Building

A building extracted from OpenStreetMap data with classified type,
footprint geometry, and estimated capacity.

# Fields
- `id::Int64` — OSM way ID
- `building_type::BuildingType` — classified function
- `centroid::Coord` — center of footprint
- `polygon::Vector{Coord}` — footprint vertices (ring, may or may not be closed)
- `area_m2::Float64` — footprint area in square meters
- `capacity::Int` — estimated person capacity
- `label::String` — human-readable name (from OSM tags or nearest road)
- `osm_tags::Dict{String,String}` — raw OSM tags for downstream use
- `nearest_node::Int64` — nearest road network node ID (0 if unmatched)
"""
struct Building
    id::Int64
    building_type::BuildingType
    centroid::Coord
    polygon::Vector{Coord}
    area_m2::Float64
    capacity::Int
    label::String
    osm_tags::Dict{String,String}
    nearest_node::Int64
end

# Keyword constructor for clarity
function Building(; id::Int64, building_type::BuildingType, centroid::Coord,
                   polygon::Vector{Coord}, area_m2::Float64, capacity::Int,
                   label::String="", osm_tags::Dict{String,String}=Dict{String,String}(),
                   nearest_node::Int64=Int64(0))
    Building(id, building_type, centroid, polygon, area_m2, capacity, label, osm_tags, nearest_node)
end

Base.show(io::IO, b::Building) =
    print(io, "Building($(b.id), $(b.building_type), cap=$(b.capacity), \"$(b.label)\")")

# ── Road ─────────────────────────────────────────────────────────────

"""
    Road

A road segment extracted from OpenStreetMap.

# Fields
- `id::Int64` — OSM way ID
- `highway_type::String` — OSM highway classification (e.g. "residential", "primary")
- `coords::Vector{Coord}` — polyline vertices
- `name::String` — road name (empty if unnamed)
- `oneway::Bool` — one-way traffic
- `lanes::Int` — number of lanes (0 if unknown)
"""
struct Road
    id::Int64
    highway_type::String
    coords::Vector{Coord}
    name::String
    oneway::Bool
    lanes::Int
end

function Road(; id::Int64, highway_type::String, coords::Vector{Coord},
               name::String="", oneway::Bool=false, lanes::Int=0)
    Road(id, highway_type, coords, name, oneway, lanes)
end

Base.show(io::IO, r::Road) =
    print(io, "Road($(r.id), \"$(r.highway_type)\", \"$(r.name)\", $(length(r.coords)) pts)")

# ── POI ──────────────────────────────────────────────────────────────

"""
    POI

Point of interest extracted from OpenStreetMap (amenity, shop, leisure, tourism).

# Fields
- `id::Int64` — OSM node or way ID
- `poi_type::String` — tag category ("amenity", "shop", "leisure", "tourism")
- `poi_value::String` — specific tag value (e.g. "restaurant", "school")
- `building_type::BuildingType` — classified building function
- `position::Coord` — location (centroid for way POIs)
- `capacity::Int` — estimated person capacity
- `name::String` — POI name from OSM tags
- `label::String` — display label (name or generated from context)
"""
struct POI
    id::Int64
    poi_type::String
    poi_value::String
    building_type::BuildingType
    position::Coord
    capacity::Int
    name::String
    label::String
end

function POI(; id::Int64, poi_type::String, poi_value::String,
              building_type::BuildingType, position::Coord, capacity::Int,
              name::String="", label::String="")
    POI(id, poi_type, poi_value, building_type, position, capacity, name, label)
end

Base.show(io::IO, p::POI) =
    print(io, "POI($(p.id), \"$(p.poi_type)=$(p.poi_value)\", \"$(p.name)\")")

# ── Settlement ───────────────────────────────────────────────────────

"""
    Settlement

A named settlement (city, town, village, hamlet) from OpenStreetMap.

# Fields
- `name::String` — original name (e.g. "Pobiedziska")
- `slug::String` — ASCII slug for file paths (e.g. "pobiedziska")
- `place_type::Symbol` — `:city`, `:town`, `:village`, or `:hamlet`
- `position::Coord` — geographic center
- `population::Int` — population (0 if unknown)
- `voivodeship::String` — province (empty if unknown)
- `powiat::String` — county/district (empty if unknown)
"""
struct Settlement
    name::String
    slug::String
    place_type::Symbol
    position::Coord
    population::Int
    voivodeship::String
    powiat::String
end

function Settlement(; name::String, slug::String, place_type::Symbol,
                     position::Coord, population::Int=0,
                     voivodeship::String="", powiat::String="")
    Settlement(name, slug, place_type, position, population, voivodeship, powiat)
end

Base.show(io::IO, s::Settlement) =
    print(io, "Settlement(\"$(s.name)\", $(s.place_type), pop=$(s.population))")

# ── RailStation ──────────────────────────────────────────────────────

"""
    RailStation

A railway station or halt from OpenStreetMap.

# Fields
- `id::Int64` — OSM node ID
- `name::String` — station name
- `position::Coord` — geographic position
- `is_halt::Bool` — true for minor stops (railway=halt), false for stations
- `operator::String` — railway operator (e.g. "PKP", empty if unknown)
"""
struct RailStation
    id::Int64
    name::String
    position::Coord
    is_halt::Bool
    operator::String
end

function RailStation(; id::Int64, name::String, position::Coord,
                      is_halt::Bool=false, operator::String="")
    RailStation(id, name, position, is_halt, operator)
end

Base.show(io::IO, s::RailStation) =
    print(io, "RailStation($(s.id), \"$(s.name)\", halt=$(s.is_halt))")

# ── RailSegment ──────────────────────────────────────────────────────

"""
    RailSegment

A railway track segment from OpenStreetMap.

# Fields
- `id::Int64` — OSM way ID
- `rail_type::Symbol` — `:rail`, `:narrow_gauge`, or `:tram`
- `coords::Vector{Coord}` — track polyline
- `electrified::Bool` — has overhead/third rail electrification
- `gauge::Int` — track gauge in mm (1435 = standard gauge)
- `maxspeed::Int` — speed limit in km/h (0 if unknown)
"""
struct RailSegment
    id::Int64
    rail_type::Symbol
    coords::Vector{Coord}
    electrified::Bool
    gauge::Int
    maxspeed::Int
end

function RailSegment(; id::Int64, rail_type::Symbol, coords::Vector{Coord},
                      electrified::Bool=false, gauge::Int=1435, maxspeed::Int=0)
    RailSegment(id, rail_type, coords, electrified, gauge, maxspeed)
end

Base.show(io::IO, s::RailSegment) =
    print(io, "RailSegment($(s.id), $(s.rail_type), $(length(s.coords)) pts)")

# ── NaturalFeature ───────────────────────────────────────────────────

"""
    NaturalFeature

A natural or landuse feature from OpenStreetMap (water, forest, park, etc.).

# Fields
- `id::Int64` — OSM way or relation ID
- `feature_type::Symbol` — `:water`, `:forest`, `:park`, `:farmland`, `:cemetery`,
  `:residential`, `:commercial`, `:industrial`
- `geometry_type::Symbol` — `:polygon` or `:linestring`
- `rings::Vector{Vector{Coord}}` — geometry rings. For polygons: outer ring + optional
  inner rings (holes). For linestrings: single ring with the line vertices.
- `name::String` — feature name (empty if unnamed)
"""
struct NaturalFeature
    id::Int64
    feature_type::Symbol
    geometry_type::Symbol
    rings::Vector{Vector{Coord}}
    name::String
end

function NaturalFeature(; id::Int64, feature_type::Symbol, geometry_type::Symbol,
                         rings::Vector{Vector{Coord}}, name::String="")
    NaturalFeature(id, feature_type, geometry_type, rings, name)
end

Base.show(io::IO, f::NaturalFeature) =
    print(io, "NaturalFeature($(f.id), $(f.feature_type), $(f.geometry_type))")
