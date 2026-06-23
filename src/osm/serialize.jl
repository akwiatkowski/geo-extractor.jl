# JSON and GeoJSON serialization for OSM extracted data.
#
# Produces GeoJSON FeatureCollections compatible with Leaflet/MapLibre.
# Also provides save/load for buildings JSON (people-sim interchange format).

using JSON3
using StructTypes

# ── GeoJSON builders ─────────────────────────────────────────────────

# Convert Coord to GeoJSON [lon, lat] pair
_geojson_coord(c::Coord) = [c.lon, c.lat]

# Convert polygon to GeoJSON coordinates (closed ring in [lon, lat] order)
function _geojson_ring(coords::Vector{Coord})
    ring = [_geojson_coord(c) for c in coords]
    # Close the ring if not already closed
    if length(ring) > 0 && ring[1] != ring[end]
        push!(ring, ring[1])
    end
    return ring
end

"""
    buildings_to_geojson(buildings::Vector{Building}) → Dict

Convert buildings to a GeoJSON FeatureCollection with Polygon geometries.

Each feature has properties: `id`, `building_type`, `area_m2`, `capacity`,
`label`, `nearest_node`.

# Examples
```julia
geojson = buildings_to_geojson(buildings)
geojson["type"]  # "FeatureCollection"
```
"""
function buildings_to_geojson(buildings::Vector{Building})::Dict{String,Any}
    features = [Dict{String,Any}(
        "type" => "Feature",
        "geometry" => Dict{String,Any}(
            "type" => "Polygon",
            "coordinates" => [_geojson_ring(b.polygon)],
        ),
        "properties" => Dict{String,Any}(
            "id" => b.id,
            "building_type" => string(b.building_type),
            "area_m2" => round(b.area_m2; digits=1),
            "capacity" => b.capacity,
            "label" => b.label,
            "nearest_node" => b.nearest_node,
        ),
    ) for b in buildings]

    return Dict{String,Any}("type" => "FeatureCollection", "features" => features)
end

"""
    roads_to_geojson(roads::Vector{Road}) → Dict

Convert roads to a GeoJSON FeatureCollection with LineString geometries.

Each feature has properties: `id`, `highway_type`, `name`, `oneway`, `lanes`.
"""
function roads_to_geojson(roads::Vector{Road})::Dict{String,Any}
    features = [Dict{String,Any}(
        "type" => "Feature",
        "geometry" => Dict{String,Any}(
            "type" => "LineString",
            "coordinates" => [_geojson_coord(c) for c in r.coords],
        ),
        "properties" => Dict{String,Any}(
            "id" => r.id,
            "highway_type" => r.highway_type,
            "name" => r.name,
            "oneway" => r.oneway,
            "lanes" => r.lanes,
        ),
    ) for r in roads]

    return Dict{String,Any}("type" => "FeatureCollection", "features" => features)
end

"""
    pois_to_geojson(pois::Vector{POI}) → Dict

Convert POIs to a GeoJSON FeatureCollection with Point geometries.

Each feature has properties: `id`, `poi_type`, `poi_value`, `building_type`,
`capacity`, `name`, `label`.
"""
function pois_to_geojson(pois::Vector{POI})::Dict{String,Any}
    features = [Dict{String,Any}(
        "type" => "Feature",
        "geometry" => Dict{String,Any}(
            "type" => "Point",
            "coordinates" => _geojson_coord(p.position),
        ),
        "properties" => Dict{String,Any}(
            "id" => p.id,
            "poi_type" => p.poi_type,
            "poi_value" => p.poi_value,
            "building_type" => string(p.building_type),
            "capacity" => p.capacity,
            "name" => p.name,
            "label" => p.label,
        ),
    ) for p in pois]

    return Dict{String,Any}("type" => "FeatureCollection", "features" => features)
end

"""
    natural_to_geojson(features::Vector{NaturalFeature}) → Dict

Convert natural features to a GeoJSON FeatureCollection.

Polygons use Polygon geometry, linestrings use LineString geometry.
"""
function natural_to_geojson(features::Vector{NaturalFeature})::Dict{String,Any}
    geojson_features = Dict{String,Any}[]
    for f in features
        geom = if f.geometry_type == :polygon
            Dict{String,Any}(
                "type" => "Polygon",
                "coordinates" => [_geojson_ring(ring) for ring in f.rings],
            )
        else  # :linestring
            Dict{String,Any}(
                "type" => "LineString",
                "coordinates" => [_geojson_coord(c) for c in f.rings[1]],
            )
        end

        push!(geojson_features, Dict{String,Any}(
            "type" => "Feature",
            "geometry" => geom,
            "properties" => Dict{String,Any}(
                "id" => f.id,
                "feature_type" => string(f.feature_type),
                "name" => f.name,
            ),
        ))
    end

    return Dict{String,Any}("type" => "FeatureCollection", "features" => geojson_features)
end

"""
    rail_to_geojson(stations::Vector{RailStation}, segments::Vector{RailSegment}) → Dict

Convert rail infrastructure to a GeoJSON FeatureCollection.

Stations become Point features, segments become LineString features.
"""
function rail_to_geojson(stations::Vector{RailStation},
                          segments::Vector{RailSegment})::Dict{String,Any}
    features = Dict{String,Any}[]

    for s in stations
        push!(features, Dict{String,Any}(
            "type" => "Feature",
            "geometry" => Dict{String,Any}(
                "type" => "Point",
                "coordinates" => _geojson_coord(s.position),
            ),
            "properties" => Dict{String,Any}(
                "id" => s.id,
                "name" => s.name,
                "is_halt" => s.is_halt,
                "operator" => s.operator,
                "feature_type" => "station",
            ),
        ))
    end

    for seg in segments
        push!(features, Dict{String,Any}(
            "type" => "Feature",
            "geometry" => Dict{String,Any}(
                "type" => "LineString",
                "coordinates" => [_geojson_coord(c) for c in seg.coords],
            ),
            "properties" => Dict{String,Any}(
                "id" => seg.id,
                "rail_type" => string(seg.rail_type),
                "electrified" => seg.electrified,
                "gauge" => seg.gauge,
                "maxspeed" => seg.maxspeed,
                "feature_type" => "segment",
            ),
        ))
    end

    return Dict{String,Any}("type" => "FeatureCollection", "features" => features)
end

"""
    settlements_to_geojson(settlements::Vector{Settlement}) → Dict

Convert settlements to a GeoJSON FeatureCollection with Point geometries.

Each feature has properties: `name`, `slug`, `place_type`, `population`.
"""
function settlements_to_geojson(settlements::Vector{Settlement})::Dict{String,Any}
    features = [Dict{String,Any}(
        "type" => "Feature",
        "geometry" => Dict{String,Any}(
            "type" => "Point",
            "coordinates" => _geojson_coord(s.position),
        ),
        "properties" => Dict{String,Any}(
            "name" => s.name,
            "slug" => s.slug,
            "place_type" => string(s.place_type),
            "population" => s.population,
        ),
    ) for s in settlements]

    return Dict{String,Any}("type" => "FeatureCollection", "features" => features)
end

# ── JSON string output ───────────────────────────────────────────────

"""
    to_json_string(data; pretty=false) → String

Serialize any data structure to a JSON string using JSON3.

# Examples
```julia
geojson = buildings_to_geojson(buildings)
json_str = to_json_string(geojson)
write("buildings.geojson", json_str)
```
"""
function to_json_string(data; pretty::Bool=false)::String
    if pretty
        return JSON3.pretty(data)
    else
        return JSON3.write(data)
    end
end

"""
    save_geojson(data::Dict, path::String; pretty=false)

Write a GeoJSON FeatureCollection dict to a file.
"""
function save_geojson(data::Dict, path::String; pretty::Bool=false)
    open(path, "w") do io
        if pretty
            JSON3.pretty(io, data)
        else
            JSON3.write(io, data)
        end
    end
end

# ── Buildings JSON interchange ───────────────────────────────────────
# Compatible with people-sim's buildings.json format

"""
    save_buildings_json(buildings::Vector{Building}, path::String)

Save buildings to a JSON file in people-sim compatible format.

Each building is serialized as a JSON object with `id`, `type`, `centroid`,
`polygon`, `area_m2`, `capacity`, `nearest_node`, `label` fields.
Coordinates use GeoJSON [lon, lat] order.
"""
function save_buildings_json(buildings::Vector{Building}, path::String)
    data = [Dict{String,Any}(
        "id" => b.id,
        "type" => string(b.building_type),
        "centroid" => _geojson_coord(b.centroid),
        "polygon" => [_geojson_coord(c) for c in b.polygon],
        "area_m2" => round(b.area_m2; digits=1),
        "capacity" => b.capacity,
        "nearest_node" => b.nearest_node,
        "label" => b.label,
    ) for b in buildings]

    open(path, "w") do io
        JSON3.pretty(io, data)
    end
end

"""
    load_buildings_json(path::String) → Vector{Building}

Load buildings from a JSON file (people-sim compatible format).
"""
function load_buildings_json(path::String)::Vector{Building}
    isfile(path) || error("Buildings JSON not found: $path")
    json_str = read(path, String)
    data = JSON3.read(json_str, Vector{Dict{String,Any}})

    buildings = Building[]
    for d in data
        btype = _parse_building_type(d["type"])
        centroid_arr = d["centroid"]
        centroid = Coord(Float64(centroid_arr[2]), Float64(centroid_arr[1]))
        polygon = [Coord(Float64(p[2]), Float64(p[1])) for p in d["polygon"]]

        push!(buildings, Building(
            Int64(d["id"]),
            btype,
            centroid,
            polygon,
            Float64(d["area_m2"]),
            Int(d["capacity"]),
            get(d, "label", ""),
            Dict{String,String}(),  # tags not preserved in JSON
            Int64(get(d, "nearest_node", 0)),
        ))
    end

    return buildings
end

function _parse_building_type(s::String)::BuildingType
    for bt in instances(BuildingType)
        string(bt) == s && return bt
    end
    return OTHER
end
