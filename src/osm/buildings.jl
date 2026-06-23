# Building extraction from parsed OSM data.
#
# Filters ways with building=* tags, computes geometry, classifies type,
# estimates capacity, and generates human-readable labels.

"""
    extract_buildings(data::OsmData) → Vector{Building}

Extract and classify all buildings from parsed OSM data.

For each way with a `building=*` tag:
1. Resolves node references to polygon coordinates
2. Computes centroid and footprint area (Shoelace formula)
3. Classifies building type from OSM tags
4. Estimates person capacity from type and area
5. Generates a label from name, address, or nearest road

Skips ways with fewer than 3 resolved nodes or area < 1 m2.

# Examples
```julia
data = parse_osm_xml("town.osm")
buildings = extract_buildings(data)
```
"""
function extract_buildings(data::OsmData)::Vector{Building}
    # Collect road names for label fallback
    road_names = _collect_road_names(data)

    buildings = Building[]
    for (id, way) in data.ways
        haskey(way.tags, "building") || continue

        # Resolve polygon coordinates
        polygon = resolve_way_coords(way, data.nodes)
        length(polygon) < 3 && continue

        # Remove closing vertex if duplicated (we store open rings)
        if length(polygon) > 1 && polygon[1] ≈ polygon[end]
            pop!(polygon)
        end
        length(polygon) < 3 && continue

        centroid = polygon_centroid(polygon)
        area = polygon_area_m2(polygon)
        area < 1.0 && continue

        btype = classify_building_type(way.tags)
        capacity = estimate_capacity(btype, area)
        label = _make_building_label(way.tags, centroid, road_names)

        push!(buildings, Building(
            id, btype, centroid, polygon, area, capacity,
            label, copy(way.tags), Int64(0),
        ))
    end

    return buildings
end

# ── Label generation ─────────────────────────────────────────────────

function _make_building_label(tags::Dict{String,String}, centroid::Coord,
                               road_names::Vector{Tuple{Coord,String}})::String
    # Priority 1: explicit name tag
    name = get(tags, "name", "")
    !isempty(name) && return name

    # Priority 2: address (street + housenumber)
    street = get(tags, "addr:street", "")
    housenumber = get(tags, "addr:housenumber", "")
    if !isempty(street)
        return isempty(housenumber) ? street : "$street $housenumber"
    end

    # Priority 3: nearest named road
    if !isempty(road_names)
        nearest = _find_nearest_road_name(centroid, road_names)
        !isempty(nearest) && return "near $nearest"
    end

    return ""
end

function _collect_road_names(data::OsmData)::Vector{Tuple{Coord,String}}
    result = Tuple{Coord,String}[]
    for (_, way) in data.ways
        road_name = get(way.tags, "name", "")
        isempty(road_name) && continue
        haskey(way.tags, "highway") || continue

        coords = resolve_way_coords(way, data.nodes)
        isempty(coords) && continue
        centroid = polygon_centroid(coords)
        push!(result, (centroid, road_name))
    end
    return result
end

function _find_nearest_road_name(centroid::Coord, road_names::Vector{Tuple{Coord,String}})::String
    best_dist = Inf
    best_name = ""
    for (rcoord, rname) in road_names
        # Quick squared-degree distance (fine for finding nearest)
        dx = centroid.lon - rcoord.lon
        dy = centroid.lat - rcoord.lat
        dist = dx * dx + dy * dy
        if dist < best_dist
            best_dist = dist
            best_name = rname
        end
    end
    return best_name
end
