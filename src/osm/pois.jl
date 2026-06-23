# Point of interest extraction from parsed OSM data.
#
# Extracts amenities, shops, leisure, tourism nodes and ways
# that are NOT already captured as buildings. Deduplicates by ID.

"""
    extract_pois(data::OsmData, buildings::Vector{Building}) → Vector{POI}

Extract points of interest from parsed OSM data, excluding features
already captured as buildings.

Checks nodes and ways for leisure, amenity, shop, and tourism tags.
For way-based POIs, computes centroid from polygon geometry.

# Examples
```julia
data = parse_osm_xml("town.osm")
buildings = extract_buildings(data)
pois = extract_pois(data, buildings)
```
"""
function extract_pois(data::OsmData, buildings::Vector{Building})::Vector{POI}
    # Set of IDs already captured as buildings
    building_ids = Set(b.id for b in buildings)

    # Collect road names for labels
    road_names = _collect_road_names(data)

    pois = POI[]

    # Extract from nodes
    for (id, node) in data.nodes
        isempty(node.tags) && continue
        id in building_ids && continue

        classification = classify_poi(node.tags)
        classification === nothing && continue

        name = get(node.tags, "name", "")
        label = _make_poi_label(name, classification.label, node.coord, road_names)

        push!(pois, POI(
            id, classification.poi_type, classification.poi_value,
            classification.building_type, node.coord,
            classification.capacity, name, label,
        ))
    end

    # Extract from ways (leisure areas, amenity buildings not tagged as building=*)
    for (id, way) in data.ways
        id in building_ids && continue
        haskey(way.tags, "building") && continue  # already handled by extract_buildings

        classification = classify_poi(way.tags)
        classification === nothing && continue

        coords = resolve_way_coords(way, data.nodes)
        length(coords) < 2 && continue
        centroid = polygon_centroid(coords)

        name = get(way.tags, "name", "")
        label = _make_poi_label(name, classification.label, centroid, road_names)

        push!(pois, POI(
            id, classification.poi_type, classification.poi_value,
            classification.building_type, centroid,
            classification.capacity, name, label,
        ))
    end

    return pois
end

function _make_poi_label(name::String, default_label::String,
                          position::Coord,
                          road_names::Vector{Tuple{Coord,String}})::String
    !isempty(name) && return name
    !isempty(default_label) && return default_label
    if !isempty(road_names)
        nearest = _find_nearest_road_name(position, road_names)
        !isempty(nearest) && return "near $nearest"
    end
    return ""
end
