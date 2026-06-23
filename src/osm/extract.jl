# High-level extraction orchestrator.
#
# Two modes:
# - Lite: parse an existing .osm file (fast, no PBF needed)
# - Smart: start from PBF + town name, two-pass osmium extraction
#   with intelligent bbox computation

"""
    ExtractionResult

Complete result of OSM data extraction for a settlement area.

Contains all extracted features and metadata about the extraction bounds.
Returned by both [`extract_from_osm`](@ref) and [`extract_settlement`](@ref).

# Fields
- `buildings::Vector{Building}`
- `roads::Vector{Road}`
- `pois::Vector{POI}`
- `natural::Vector{NaturalFeature}`
- `rail_stations::Vector{RailStation}`
- `rail_segments::Vector{RailSegment}`
- `settlements::Vector{Settlement}`
- `bbox::BBox` — bounding box of the extracted area
- `center::Coord` — center of the target settlement
- `target_settlement::Settlement` — the primary settlement that was extracted
"""
struct ExtractionResult
    buildings::Vector{Building}
    roads::Vector{Road}
    pois::Vector{POI}
    natural::Vector{NaturalFeature}
    rail_stations::Vector{RailStation}
    rail_segments::Vector{RailSegment}
    settlements::Vector{Settlement}
    bbox::BBox
    center::Coord
    target_settlement::Settlement
end

# ── Lite mode ────────────────────────────────────────────────────────

"""
    extract_from_osm(osm_path::String) → ExtractionResult

Parse an existing OSM XML file and extract all features (lite mode).

No PBF or osmium needed. The bbox is computed from building and POI positions.
The first settlement found becomes the target settlement.

# Examples
```julia
result = extract_from_osm("town.osm")
length(result.buildings)  # number of buildings
```
"""
function extract_from_osm(osm_path::String)::ExtractionResult
    data = parse_osm_xml(osm_path)

    buildings = extract_buildings(data)
    roads = extract_roads(data)
    pois = extract_pois(data, buildings)
    natural = extract_natural_features(data)
    stations = extract_rail_stations(data)
    segments = extract_rail_segments(data)
    settlements = find_settlements(data)

    # Compute bbox from point features
    all_coords = Coord[]
    for b in buildings; push!(all_coords, b.centroid); end
    for p in pois; push!(all_coords, p.position); end
    for r in roads; append!(all_coords, r.coords); end

    bbox = isempty(all_coords) ? BBox(-90, -180, 90, 180) : bbox_from_coords(all_coords)
    c = center(bbox)

    # Find target settlement (prefer towns/cities)
    target = if !isempty(settlements)
        type_priority = Dict(:city => 1, :town => 2, :village => 3, :hamlet => 4)
        sort(settlements; by=s -> get(type_priority, s.place_type, 99))[1]
    else
        Settlement("Unknown", "unknown", :town, c, 0, "", "")
    end

    return ExtractionResult(buildings, roads, pois, natural, stations, segments,
                             settlements, bbox, c, target)
end

# ── Smart mode ───────────────────────────────────────────────────────

"""
    extract_settlement(pbf_path::String, town_name::String;
                        buffer_km::Float64=3.0,
                        workdir::String=tempdir()) → ExtractionResult

Extract a complete settlement area from a PBF file using smart bbox computation.

Two-pass approach:
1. Find the town by name, extract a small core area, parse buildings/POIs
2. Compute a tight bbox from building/POI positions (not highway geometries),
   square it up, add buffer, then extract ALL features in that area

This captures the town plus surrounding villages, forests, connecting roads.

# Arguments
- `pbf_path` — path to the PBF file (e.g. poland-latest.osm.pbf)
- `town_name` — settlement name to search for (case-insensitive)
- `buffer_km` — buffer around the town in kilometers (default: 3.0)
- `workdir` — directory for temporary osmium output files

# Examples
```julia
result = extract_settlement("poland.pbf", "Szamocin"; buffer_km=3.0)
length(result.buildings)
result.target_settlement.name  # "Szamocin"
```
"""
function extract_settlement(pbf_path::String, town_name::String;
                              buffer_km::Float64=3.0,
                              workdir::String=tempdir())::ExtractionResult
    _require_osmium()
    isfile(pbf_path) || error("PBF file not found: $pbf_path")
    mkpath(workdir)

    # Step 1: Find the town in the PBF
    println("  [1/5] Finding settlement '$town_name'...")
    town_center = _find_town_in_pbf(pbf_path, town_name, workdir)

    # Step 2: Extract small core area to get buildings/POIs
    println("  [2/5] Extracting town core...")
    core_bbox = _make_core_bbox(town_center, 0.03)
    core_osm = joinpath(workdir, "_town_core.osm")
    osmium_extract_bbox(pbf_path, core_bbox, core_osm)

    core_data = parse_osm_xml(core_osm)
    core_buildings = extract_buildings(core_data)
    core_pois = extract_pois(core_data, core_buildings)

    # If too few buildings, widen the search
    if length(core_buildings) < 10
        println("    Few buildings found ($(length(core_buildings))), widening search...")
        core_bbox = _make_core_bbox(town_center, 0.06)
        osmium_extract_bbox(pbf_path, core_bbox, core_osm)
        core_data = parse_osm_xml(core_osm)
        core_buildings = extract_buildings(core_data)
        core_pois = extract_pois(core_data, core_buildings)
    end
    println("    Found $(length(core_buildings)) buildings, $(length(core_pois)) POIs in core")

    # Step 3: Compute smart bbox from point features
    println("  [3/5] Computing smart bbox...")
    point_coords = Coord[]
    for b in core_buildings; push!(point_coords, b.centroid); end
    for p in core_pois; push!(point_coords, p.position); end
    push!(point_coords, town_center)  # always include the town center

    smart_bbox = _compute_smart_bbox(point_coords, buffer_km)
    println("    BBox: $(round(width_m(smart_bbox)/1000; digits=1))km × $(round(height_m(smart_bbox)/1000; digits=1))km")

    # Step 4: Full extraction with smart bbox
    println("  [4/5] Extracting full area...")
    full_osm = joinpath(workdir, "_area.osm")
    osmium_extract_bbox(pbf_path, smart_bbox, full_osm)

    # Step 5: Parse everything
    println("  [5/5] Parsing all features...")
    data = parse_osm_xml(full_osm)

    buildings = extract_buildings(data)
    roads = extract_roads(data)
    pois = extract_pois(data, buildings)
    natural = extract_natural_features(data)
    stations = extract_rail_stations(data)
    segments = extract_rail_segments(data)
    settlements = find_settlements(data)

    # Find target settlement
    target = find_settlement(data, town_name)
    if target === nothing
        target = Settlement(town_name, slugify(town_name), :town, town_center, 0, "", "")
    end

    println("    $(length(buildings)) buildings, $(length(roads)) roads, " *
            "$(length(pois)) POIs, $(length(natural)) natural, " *
            "$(length(settlements)) settlements")

    return ExtractionResult(buildings, roads, pois, natural, stations, segments,
                             settlements, smart_bbox, town_center, target)
end

# ── Internal helpers ─────────────────────────────────────────────────

"""Find a town's center coordinate by filtering settlements from PBF."""
function _find_town_in_pbf(pbf_path::String, town_name::String, workdir::String)::Coord
    settlements_pbf = joinpath(workdir, "_settlements.osm.pbf")
    settlements_osm = joinpath(workdir, "_settlements.osm")

    # Filter for settlement nodes only (very fast)
    osmium_tags_filter(pbf_path, ["n/place=city,town,village,hamlet"], settlements_pbf)

    # Convert PBF to OSM XML for parsing
    run(`osmium cat $settlements_pbf -o $settlements_osm --overwrite`)

    data = parse_osm_xml(settlements_osm)
    settlement = find_settlement(data, town_name)

    settlement === nothing && error("Settlement '$town_name' not found in PBF file")
    println("    Found: $(settlement.name) ($(settlement.place_type), pop=$(settlement.population)) " *
            "at $(round(settlement.position.lat; digits=4)), $(round(settlement.position.lon; digits=4))")

    return settlement.position
end

"""Create a bbox around a center point with given half-size in degrees."""
function _make_core_bbox(center::Coord, half_deg::Float64)::BBox
    BBox(center.lat - half_deg, center.lon - half_deg,
         center.lat + half_deg, center.lon + half_deg)
end

"""
Compute a smart bbox from point coordinates: square it up and add buffer.

The bbox is computed from the point positions, then squared (max of width/height
applied to both dimensions), then buffered by `buffer_km` kilometers.
"""
function _compute_smart_bbox(coords::Vector{Coord}, buffer_km::Float64)::BBox
    isempty(coords) && error("No coordinates to compute bbox from")

    raw_bbox = bbox_from_coords(coords)

    # Square it up: use the larger dimension for both
    w = width_m(raw_bbox)
    h = height_m(raw_bbox)
    max_dim = max(w, h)

    c = center(raw_bbox)
    half_m = max_dim / 2.0

    # Build a square bbox centered on the data center
    square_bbox = BBox(
        c.lat - half_m / (DEG_TO_RAD * EARTH_RADIUS_M),
        c.lon - half_m / (DEG_TO_RAD * EARTH_RADIUS_M * cos(c.lat * DEG_TO_RAD)),
        c.lat + half_m / (DEG_TO_RAD * EARTH_RADIUS_M),
        c.lon + half_m / (DEG_TO_RAD * EARTH_RADIUS_M * cos(c.lat * DEG_TO_RAD)),
    )

    # Add buffer
    return expand_bbox(square_bbox, buffer_km * 1000.0)
end
