# render3d engine — port of osm-explorer-2's build_world (Python) to Julia.
#
# Converts the neutral OSM model + DEM into a local-meter 3D scene (scene.json)
# that the osm-explorer-2 browser viewer loads. Golden-gated against world.json.
# Frame + heuristics mirror tools/extract_world.py:
#   - local frame: +X east, +Z south, equirectangular, 111320 m/deg
#   - ORDERED way classifier (first match wins), exactly as the Python WorldHandler
#   - building height/kind, road width/surface, area kinds, barriers, rails, terrain
#
# Terrain heights come from the SRTM1 30 m source (vs explorer's 90 m), so terrain
# VALUES intentionally differ from the golden; the grid SHAPE (cols/rows/resolution)
# matches. All other layers reproduce the golden counts.

const METERS_PER_LEVEL = 2.8
const M_PER_DEG = 111320.0
const TERRAIN_RESOLUTION = 2.0
const BACKDROP_HALF_M = 3000.0
const BACKDROP_RESOLUTION = 80.0

const ROAD_WIDTHS = Dict(
    "motorway" => 14.0, "trunk" => 10.0, "primary" => 9.0, "secondary" => 8.0,
    "tertiary" => 7.0, "residential" => 5.0, "living_street" => 4.0, "service" => 3.5,
    "track" => 2.5, "path" => 1.5, "footway" => 1.5, "cycleway" => 2.0,
    "unclassified" => 5.0, "pedestrian" => 4.0,
)
const DEFAULT_ROAD_WIDTH = 5.0
const DIRT_HIGHWAYS  = Set(["path", "footway", "bridleway", "steps"])
const DIRT_SURFACES  = Set(["dirt", "ground", "earth", "mud", "grass", "sand"])
const GRAVEL_SURFACES = Set(["gravel", "fine_gravel", "compacted", "unpaved", "pebblestone"])
const PAVED_SURFACES = Set(["asphalt", "concrete", "paved", "paving_stones", "sett", "cobblestone", "chipseal"])
const POWER_LINE_VALUES = Set(["line", "minor_line"])
const RAIL_WAY_VALUES = Set(["rail", "narrow_gauge", "light_rail", "tram", "disused", "abandoned"])
const MANMADE_LANDMARKS = Set(["water_tower", "silo", "chimney", "mast", "tower", "communications_tower", "storage_tank", "windmill", "lighthouse"])
const HISTORIC_POIS = Set(["wayside_shrine", "wayside_cross"])
const BARRIER_KINDS = Dict("wall" => ("wall", 1.8), "city_wall" => ("wall", 3.0),
                           "fence" => ("fence", 1.5), "hedge" => ("hedge", 1.2))
# Ordered (tagset → area kind); first match wins (scrub/orchard/vineyard before grass).
const _AREA_TAGSETS = [
    ([("landuse", "forest"), ("natural", "wood")], "forest"),
    ([("natural", "scrub")], "scrub"),
    ([("landuse", "orchard")], "orchard"),
    ([("landuse", "vineyard")], "vineyard"),
    ([("landuse", "allotment")], "allotment"),
    ([("leisure", "pitch"), ("leisure", "stadium")], "pitch"),
    ([("landuse", "meadow"), ("landuse", "grass"), ("landuse", "village_green"),
      ("natural", "grassland"), ("leisure", "park")], "grass"),
    ([("landuse", "farmland")], "farmland"),
]
const _LAWN_TAGS = [("leisure", "park"), ("landuse", "village_green")]

# ---- tag helpers ------------------------------------------------------------
_haspair(tags, set) = any(p -> get(tags, p[1], nothing) == p[2], set)

function parse_height_m(s)
    s === nothing && return nothing
    m = match(r"[-+]?[0-9]*\.?[0-9]+", s)
    m === nothing ? nothing : parse(Float64, m.match)
end

function building_height(tags)
    h = parse_height_m(get(tags, "height", nothing))
    h === nothing && (h = parse_height_m(get(tags, "building:height", nothing)))
    levels = nothing
    rl = get(tags, "building:levels", nothing)
    if rl !== nothing
        v = tryparse(Float64, rl)
        v !== nothing && (levels = clamp(Int(floor(v)), 1, 50))
    end
    (h === nothing && levels !== nothing) && (h = levels * METERS_PER_LEVEL)
    return h, levels
end

function building_kind(tags)
    amenity = get(tags, "amenity", ""); bt = get(tags, "building", "yes")
    (bt in ("church", "chapel", "cathedral") || amenity == "place_of_worship") && return "church"
    (bt in ("industrial", "warehouse", "hangar") || get(tags, "landuse", "") == "industrial") && return "industrial"
    bt in ("farm", "barn", "shed", "sty", "cowshed", "stable", "farm_auxiliary") && return "barn"
    bt in ("garage", "garages", "carport") && return "garage"
    (amenity == "school" || bt in ("school", "university", "kindergarten", "college")) && return "school"
    (amenity in ("hospital", "clinic") || bt in ("hospital", "clinic")) && return "hospital"
    (amenity == "townhall" || bt in ("civic", "government", "public")) && return "townhall"
    (bt in ("apartments", "dormitory") || amenity in ("library", "community_centre", "fire_station", "police", "post_office")) && return "block"
    (bt in ("retail", "commercial", "office", "supermarket") || haskey(tags, "shop") || amenity in ("restaurant", "cafe", "bar", "pub", "fast_food", "bank", "atm", "pharmacy", "fuel")) && return "commercial"
    return "house"
end

function road_surface(tags)
    hw = get(tags, "highway", ""); s = get(tags, "surface", "")
    s in PAVED_SURFACES && return "asphalt"
    s in DIRT_SURFACES && return "dirt"
    s in GRAVEL_SURFACES && return "gravel"
    hw in DIRT_HIGHWAYS && return "dirt"
    hw == "track" && return "gravel"
    return "asphalt"
end

function area_kind(tags)
    for (set, kind) in _AREA_TAGSETS
        _haspair(tags, set) && return kind
    end
    (get(tags, "natural", "") == "water" || get(tags, "landuse", "") in ("reservoir", "basin")) && return "water"
    get(tags, "natural", "") == "wetland" && return "wetland"
    (get(tags, "landuse", "") == "cemetery" || get(tags, "amenity", "") == "grave_yard") && return "cemetery"
    return nothing
end

grass_subkind(tags) = _haspair(tags, _LAWN_TAGS) ? "lawn" : "meadow"

function tree_leaf_type(tags)
    lt = get(tags, "leaf_type", "")
    lt in ("broadleaved", "broadleaf") && return "broadleaf"
    lt in ("needleleaved", "needleleaf") && return "needleleaf"
    lt == "mixed" && return "mixed"
    return nothing
end

forest_leaf(tags) = tree_leaf_type(tags)

barrier_kind(tags) = get(BARRIER_KINDS, get(tags, "barrier", ""), nothing)

function rail_state(tags)
    rw = get(tags, "railway", "")
    rw in ("disused", "abandoned") && return rw
    (haskey(tags, "abandoned:railway") || get(tags, "abandoned", "") == "yes") && return "abandoned"
    (haskey(tags, "disused:railway") || get(tags, "disused", "") == "yes") && return "disused"
    return "active"
end

rail_electrified(tags) = !(get(tags, "electrified", "no") in ("no", "", "contact_line:no"))

# ---- local-frame conversion -------------------------------------------------
function to_local(c::Coord, center::Coord)
    mlon = M_PER_DEG * cos(center.lat * pi / 180)
    return ((c.lon - center.lon) * mlon, -(c.lat - center.lat) * M_PER_DEG)
end
_r2(x) = round(x; digits=2)
_llpt(c::Coord, center::Coord) = (xz = to_local(c, center); [_r2(xz[1]), _r2(xz[2])])

function local_ring(coords::Vector{Coord}, center::Coord)
    pts = [to_local(c, center) for c in coords]
    (length(pts) > 1 && pts[1] == pts[end]) && (pts = pts[1:end-1])
    return [[_r2(x), _r2(z)] for (x, z) in pts]
end
local_path(coords::Vector{Coord}, center::Coord) =
    [[_r2(x), _r2(z)] for (x, z) in (to_local(c, center) for c in coords)]
rings(areas, kind, center) = [local_ring(cw[1], center) for cw in get(areas, kind, [])]

# ---- terrain ----------------------------------------------------------------
"""Resample the SRTM1 DEM onto a cols×rows grid over `bb` (bilinear). Returns the
grid as a Matrix indexed [col,row] (row 1 = north), or nothing if no tiles."""
function _resample_grid(bb::BBox, cols::Int, rows::Int)
    tiles = tiles_for_bbox(bb)
    isempty(tiles) && return nothing
    src = [AG.read(t) for t in tiles]
    tmp = tempname() * ".tif"
    grid = nothing
    AG.gdalwarp(src, ["-te", string(bb.min_lon), string(bb.min_lat), string(bb.max_lon),
                      string(bb.max_lat), "-ts", string(cols), string(rows),
                      "-r", "bilinear", "-of", "GTiff"]; dest=tmp) do ds
        grid = Float64.(AG.read(ds, 1))   # [col, row], row 1 = north (north-up)
    end
    isfile(tmp) && rm(tmp; force=true)
    return grid
end

"""Build the fine terrain block: heights relative to center, row-major N→S."""
function build_terrain(ctx::Ctx)
    bb = ctx.bbox
    width_m = (bb.max_lon - bb.min_lon) * M_PER_DEG * cos(ctx.center.lat * pi / 180)
    height_m = (bb.max_lat - bb.min_lat) * M_PER_DEG
    cols = max(2, floor(Int, width_m / TERRAIN_RESOLUTION) + 1)
    rows = max(2, floor(Int, height_m / TERRAIN_RESOLUTION) + 1)
    grid = _resample_grid(bb, cols, rows)
    center_elev = grid === nothing ? 0.0 : grid[cld(cols, 2), cld(rows, 2)]
    heights = Vector{Float64}(undef, rows * cols)
    k = 1
    for r in 1:rows, c in 1:cols
        heights[k] = grid === nothing ? 0.0 : round(grid[c, r] - center_elev; digits=2)
        k += 1
    end
    return Dict("cols" => cols, "rows" => rows, "resolution" => TERRAIN_RESOLUTION,
                "centerElevation" => round(center_elev; digits=2), "heights" => heights)
end

"""Coarse distant-terrain backdrop ring (same frame, low resolution)."""
function build_backdrop(ctx::Ctx, center_elev::Float64)
    bb = square_bbox(ctx.center, 2 * BACKDROP_HALF_M)
    n = max(2, floor(Int, (2 * BACKDROP_HALF_M) / BACKDROP_RESOLUTION) + 1)
    grid = _resample_grid(bb, n, n)
    heights = Vector{Float64}(undef, n * n)
    k = 1
    for r in 1:n, c in 1:n
        heights[k] = grid === nothing ? 0.0 : round(grid[c, r] - center_elev; digits=1)
        k += 1
    end
    return Dict("cols" => n, "rows" => n, "resolution" => BACKDROP_RESOLUTION,
                "halfExtent" => BACKDROP_HALF_M, "heights" => heights)
end

# ---- the engine -------------------------------------------------------------
"""
render3d engine: neutral model + DEM → render3d/scene.json.gz (local-meter scene).
Replicates osm-explorer-2's ordered way classifier and all scene layers.
"""
function run_render3d!(ctx::Ctx)
    center, data = ctx.center, ctx.data

    # Ordered way classification — first match wins (mirrors WorldHandler.way).
    buildings_w = Vector{Tuple{Vector{Coord},Dict{String,String}}}()
    roads_w = similar(buildings_w, 0); waterways_w = similar(buildings_w, 0)
    barriers_w = similar(buildings_w, 0); power_w = similar(buildings_w, 0)
    rails_w = similar(buildings_w, 0); platforms_w = similar(buildings_w, 0)
    treerows_w = similar(buildings_w, 0)
    areas = Dict(k => Vector{Tuple{Vector{Coord},Dict{String,String}}}() for k in
                 ("forest", "grass", "scrub", "orchard", "vineyard", "allotment", "pitch", "farmland", "water", "wetland", "cemetery"))
    for id in sort(collect(keys(data.ways)))
        w = data.ways[id]; t = w.tags
        coords = resolve_way_coords(w, data.nodes)
        length(coords) < 2 && continue
        if get(t, "building", "no") != "no" && length(coords) >= 3
            push!(buildings_w, (coords, t)); continue
        end
        if haskey(t, "highway") && !(t["highway"] in ("street_lamp", "proposed", "construction"))
            push!(roads_w, (coords, t)); continue
        end
        if get(t, "waterway", "") in ("river", "stream", "canal", "ditch", "drain")
            push!(waterways_w, (coords, t)); continue
        end
        if barrier_kind(t) !== nothing
            push!(barriers_w, (coords, t)); continue
        end
        if get(t, "power", "") in POWER_LINE_VALUES
            push!(power_w, (coords, t)); continue
        end
        rw = get(t, "railway", "")
        if rw in RAIL_WAY_VALUES
            push!(rails_w, (coords, t)); continue
        end
        if rw == "platform" || get(t, "public_transport", "") == "platform"
            push!(platforms_w, (coords, t)); continue
        end
        if get(t, "natural", "") == "tree_row"
            push!(treerows_w, (coords, t)); continue
        end
        k = area_kind(t)
        (k !== nothing && length(coords) >= 3) && push!(areas[k], (coords, t))
    end

    buildings = map(buildings_w) do (coords, t)
        h, levels = building_height(t)
        Dict("footprint" => local_ring(coords, center),
             "height" => h === nothing ? nothing : _r2(h), "levels" => levels,
             "kind" => building_kind(t), "roofShape" => get(t, "roof:shape", nothing),
             "name" => get(t, "name", nothing), "housenumber" => get(t, "addr:housenumber", nothing),
             "shop" => get(t, "shop", nothing),
             "amenity" => get(t, "amenity", nothing),
             "buildingMaterial" => get(t, "building:material", nothing),
             "roofMaterial" => get(t, "roof:material", nothing),
             "buildingColour" => get(t, "building:colour", nothing),
             "roofColour" => get(t, "roof:colour", nothing))
    end
    function _parse_int_or_nothing(s)
        s === nothing && return nothing
        v = tryparse(Int, s)
        return v === nothing ? nothing : v
    end

    roads = map(roads_w) do (coords, t)
        hw = get(t, "highway", "residential")
        Dict("path" => local_path(coords, center), "highway" => hw,
             "width" => get(ROAD_WIDTHS, hw, DEFAULT_ROAD_WIDTH),
             "surface" => road_surface(t), "name" => get(t, "name", nothing),
             "oneway" => get(t, "oneway", "no") == "yes",
             "lanes" => _parse_int_or_nothing(get(t, "lanes", nothing)),
             "maxspeed" => _parse_int_or_nothing(get(t, "maxspeed", nothing)))
    end
    waterways = map(waterways_w) do (coords, t)
        w = parse_height_m(get(t, "width", nothing))
        Dict("path" => local_path(coords, center),
             "width" => w !== nothing ? w : (get(t, "waterway", "") == "river" ? 8.0 : 2.0))
    end
    barriers = map(barriers_w) do (coords, t)
        kind, dh = barrier_kind(t)
        Dict("path" => local_path(coords, center), "kind" => kind,
             "height" => round(something(parse_height_m(get(t, "height", nothing)), dh); digits=2))
    end
    power_lines = map(power_w) do (coords, t)
        Dict("path" => local_path(coords, center), "minor" => get(t, "power", "") == "minor_line")
    end
    rails = map(rails_w) do (coords, t)
        Dict("path" => local_path(coords, center), "state" => rail_state(t),
             "electrified" => rail_electrified(t), "service" => get(t, "service", nothing))
    end
    _is_area(coords, t) = get(t, "area", "") == "yes" || (length(coords) >= 4 && coords[1] == coords[end])
    platforms = map(platforms_w) do (coords, t)
        Dict("path" => local_path(coords, center), "area" => _is_area(coords, t))
    end

    # Node-tagged points.
    trees = Vector{Any}(); tree_attrs = Vector{Any}(); lamps = Vector{Any}()
    stations = Vector{Any}(); bus_stops = Vector{Any}(); landmarks = Vector{Any}()
    for nid in sort(collect(keys(data.nodes)))
        n = data.nodes[nid]; t = n.tags
        isempty(t) && continue
        if get(t, "natural", "") == "tree"
            push!(trees, _llpt(n.coord, center))
            h = parse_height_m(get(t, "height", nothing))
            push!(tree_attrs, Dict("leafType" => tree_leaf_type(t),
                                   "height" => h === nothing ? nothing : _r2(h)))
        elseif get(t, "highway", "") == "street_lamp"
            push!(lamps, _llpt(n.coord, center))
        elseif get(t, "railway", "") in ("station", "halt")
            xz = to_local(n.coord, center)
            push!(stations, Dict("x" => _r2(xz[1]), "z" => _r2(xz[2]),
                                 "name" => get(t, "name", nothing), "halt" => get(t, "railway", "") == "halt"))
        elseif get(t, "highway", "") == "bus_stop"
            xz = to_local(n.coord, center)
            push!(bus_stops, Dict("x" => _r2(xz[1]), "z" => _r2(xz[2]),
                                  "name" => get(t, "name", nothing),
                                  "shelter" => get(t, "shelter", "no") == "yes",
                                  "bench" => get(t, "bench", "no") == "yes"))
        elseif get(t, "man_made", "") in MANMADE_LANDMARKS
            xz = to_local(n.coord, center)
            push!(landmarks, Dict("x" => _r2(xz[1]), "z" => _r2(xz[2]), "kind" => t["man_made"]))
        elseif get(t, "historic", "") in HISTORIC_POIS
            xz = to_local(n.coord, center)
            push!(landmarks, Dict("x" => _r2(xz[1]), "z" => _r2(xz[2]), "kind" => t["historic"]))
        end
    end

    terrain = build_terrain(ctx)
    backdrop = build_backdrop(ctx, terrain["centerElevation"])
    climate = get(ctx.extra, "climate", nothing)

    # GUGiK cadastral plot borders (cached local input, optionally populated by
    # the ULDK downloader when GUGIK_DOWNLOAD=1).
    download_gugik_plots!(first.(buildings_w))
    plots = map(load_gugik_plots(ctx.bbox)) do (coords, id)
        Dict("footprint" => local_ring(coords, center), "id" => id)
    end

    scene = Dict(
        "name" => ctx.label, "lat" => center.lat, "lon" => center.lon, "sizeMeters" => ctx.extent_m,
        "terrain" => terrain,
        "climate" => climate,
        "buildings" => buildings, "roads" => roads,
        "forests" => rings(areas, "forest", center),
        "forestLeaf" => [forest_leaf(cw[2]) for cw in areas["forest"]],
        "grass" => rings(areas, "grass", center),
        "grassKinds" => [grass_subkind(cw[2]) for cw in areas["grass"]],
        "scrub" => rings(areas, "scrub", center),
        "orchards" => rings(areas, "orchard", center),
        "orchardProduce" => [get(cw[2], "produce", nothing) for cw in areas["orchard"]],
        "vineyards" => rings(areas, "vineyard", center),
        "vineyardProduce" => [get(cw[2], "produce", nothing) for cw in areas["vineyard"]],
        "allotments" => rings(areas, "allotment", center),
        "pitches" => rings(areas, "pitch", center),
        "pitchSports" => [get(cw[2], "sport", nothing) for cw in areas["pitch"]],
        "cemeteries" => rings(areas, "cemetery", center),
        "farmland" => rings(areas, "farmland", center),
        "farmlandCrops" => [get(cw[2], "crop", nothing) for cw in areas["farmland"]],
        "water" => rings(areas, "water", center),
        "wetlands" => rings(areas, "wetland", center),
        "waterways" => waterways, "barriers" => barriers, "powerLines" => power_lines,
        "plots" => plots,
        "rails" => rails, "stations" => stations, "platforms" => platforms,
        "trees" => trees, "treeAttrs" => tree_attrs,
        "treeRows" => [local_path(cw[1], center) for cw in treerows_w],
        "landmarks" => landmarks, "lamps" => lamps, "busStops" => bus_stops,
        "backdrop" => backdrop,
    )
    rdir = joinpath(ctx.dir, "render3d"); mkpath(rdir)
    path = joinpath(rdir, "scene.json")
    open(path, "w") do io
        JSON3.write(io, scene)
    end
    run(`gzip -f $path`)
    @info "Extractor: render3d engine" buildings=length(buildings) roads=length(roads) terrain="$(terrain["cols"])x$(terrain["rows"])"
    return nothing
end
