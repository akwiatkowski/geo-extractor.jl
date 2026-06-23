"""
    Extractor

Unified geo-data extractor: clips a region once from the Poland PBF (+ DEM) and
emits a per-region data bundle that several apps consume — microsim (transit sim),
osm-explorer-2 (3D viewer), cycling-route-generator (router).

A region is addressed by its **quantized center** (`round(lat,precision)_round(lon,precision)`)
under `~/projects/llm/output/geo-extracts/<cell>/`. Extraction is **grow-only**: a
request whose bbox fits inside a cached cell is a hit; otherwise the cell is
re-extracted at the larger extent.

This file is the skeleton: it lays out the cell directory and writes `meta.json`.
The actual work is done by toggleable **engines** (ACQUIRE, PARSE, feature engines,
elevation, render3d, routing) added in later tasks.

See the design in `~/projects/claude/plans/miasteczko-jl.md § "GEO EXTRACTION UNIFICATION"`.
"""
module Extractor

using ..Geo: Coord, BBox, expand_bbox
using ..OSM: osmium_extract_bbox, parse_osm_xml, OsmData, resolve_way_coords, slugify, extract_from_osm
using Dates
import JSON3
import StructTypes
import ArchGDAL as AG

include("gugik_plots.jl")

# Bumped when the on-disk layout / semantics change, so stale cells are detected.
const EXTRACTOR_VERSION = 1
# Canonical elevation source tag (SRTM1 = 1 arc-second ≈ 30 m).
const SRTM_VERSION = "SRTM1-30m"
# All region bundles live here. Generated-from-input data → belongs under output/.
const OUTPUT_ROOT = joinpath(homedir(), "projects", "llm", "output", "geo-extracts")
# SRTM1 (30 m) HGT tiles, gzipped, named N{lat}E{lon}.hgt.gz (shared with cycling).
const SRTM_DIR = joinpath(homedir(), "projects", "llm", "input", "srtm")

"""Quantized cell key for a center coordinate, e.g. (52.999,17.07) → "53.0_17.07" at precision 3."""
cell_key(c::Coord, precision::Int) = string(round(c.lat; digits=precision), "_", round(c.lon; digits=precision))

"""
Square region bbox of side `extent_m` (meters) centered on `c`.

We expand a degenerate (zero-size) bbox at the center by half the side length on
every edge — `expand_bbox` handles the metres→degrees conversion (incl. the
cos(lat) longitude correction).
"""
square_bbox(c::Coord, extent_m::Real)::BBox =
    expand_bbox(BBox(c.lat, c.lon, c.lat, c.lon), extent_m / 2)

"""Path to the source Poland PBF (from the `LLM_OSM` env var)."""
pbf_path()::String = joinpath(get(ENV, "LLM_OSM", ""), "poland-latest.osm.pbf")

"""Date of the source PBF (for cache invalidation); "unknown" if not found."""
function pbf_date()::String
    p = pbf_path()
    isfile(p) ? Dates.format(unix2datetime(mtime(p)), "yyyy-mm-dd") : "unknown"
end

"""Read a cell's existing meta.json, or `nothing` if absent."""
function read_meta(dir::String)
    f = joinpath(dir, "meta.json")
    isfile(f) || return nothing
    return JSON3.read(read(f, String))
end

"""Which engines have produced outputs in this cell, detected by artifact presence."""
function present_engines(dir::String)::Vector{String}
    p = String[]
    for cls in ("buildings", "roads", "rail", "water", "landcover", "pois", "settlements")
        isfile(joinpath(dir, "features", "$cls.geojson.gz")) && push!(p, cls)
    end
    isfile(joinpath(dir, "elevation.tif")) && push!(p, "elevation")
    isfile(joinpath(dir, "render3d", "scene.json.gz")) && push!(p, "render3d")
    isfile(joinpath(dir, "routing", "graph.msgpack.zst")) && push!(p, "routing")
    return p
end

"""Upsert this cell into `geo-extracts/manifest.json` — the cross-cell discovery index."""
function update_manifest!(meta)
    mf = joinpath(OUTPUT_ROOT, "manifest.json")
    entries = Any[]
    if isfile(mf)
        for c in JSON3.read(read(mf, String)).cells
            string(c.cell) == meta["cell"] && continue   # drop the old version of this cell
            push!(entries, c)
        end
    end
    push!(entries, Dict(
        "cell" => meta["cell"], "slug" => meta["slug"], "label" => meta["label"],
        "center" => meta["center"], "bbox" => meta["bbox"],
        "extent_m" => meta["extent_m"], "engines_present" => meta["engines_present"],
    ))
    open(mf, "w") do io
        JSON3.pretty(io, JSON3.write(Dict("cells" => entries)))
    end
end

"""
    parse_cell(dir) -> OsmData

PARSE step: read the cell's PBF clip into the neutral OSM model (nodes/ways/tags
with lat/lon). The clip is binary PBF; we `osmium cat` it to a throwaway XML file
(tiny + instant for a region clip) and feed the existing `OSM.parse_osm_xml`, so the
compact PBF stays the on-disk artifact. Feature engines resolve way geometry from
this model when they emit. Errors if ACQUIRE hasn't run.
"""
function parse_cell(dir::String)::OsmData
    clip = joinpath(dir, "area.osm.pbf")
    isfile(clip) || error("no clip in $dir — run ACQUIRE (extract) first")
    tmp = tempname() * ".osm"
    try
        run(`osmium cat $clip -o $tmp --overwrite`)
        return parse_osm_xml(tmp)
    finally
        isfile(tmp) && rm(tmp; force=true)
    end
end

"""
    extraction_result(cell_dir) -> OSM.ExtractionResult

microsim integration path: build the full classified `ExtractionResult`
(buildings+capacity, roads, pois, natural, rail, settlements) from a shared
geo-extracts cell, so microsim consumes the cached/grow-only extractor output
instead of doing its own one-off osmium clip.

In-process Julia consumers use the rich OSM model directly (the neutral GeoJSON is
the cross-language seam for cycling/the browser). We reuse the existing
`OSM.extract_from_osm` classification pipeline on the cell's clip, so the result is
identical to the pre-unification path on the same region.
"""
function extraction_result(cell_dir::String)
    clip = joinpath(cell_dir, "area.osm.pbf")
    isfile(clip) || error("no clip in $cell_dir — run extract() first")
    tmp = tempname() * ".osm"
    try
        run(`osmium cat $clip -o $tmp --overwrite`)
        return extract_from_osm(tmp)
    finally
        isfile(tmp) && rm(tmp; force=true)
    end
end

# ============================================================
# Feature emit helpers (neutral GeoJSON: 7-decimal lon/lat, raw tags as properties)
# ============================================================

"""Extraction context handed to each engine's `run!`. `extra` collects fields an
engine wants merged into the cell's meta.json (e.g. the elevation grid shape)."""
struct Ctx
    dir::String
    data::OsmData
    bbox::BBox
    center::Coord
    extent_m::Float64
    label::String
    extra::Dict{String,Any}
end

const COORD_DIGITS = 7   # OSM-native precision; cycling's coordHash needs ≥7 to rebuild topology
lonlat(c::Coord) = [round(c.lon; digits=COORD_DIGITS), round(c.lat; digits=COORD_DIGITS)]

"""GeoJSON Polygon feature (single closed ring) carrying the raw OSM tags."""
function polygon_feature(coords::Vector{Coord}, tags::Dict{String,String})
    ring = [lonlat(c) for c in coords]
    isempty(ring) || ring[1] == ring[end] || push!(ring, ring[1])  # close the ring
    Dict("type" => "Feature",
         "geometry" => Dict("type" => "Polygon", "coordinates" => [ring]),
         "properties" => tags)
end

"""Write a FeatureCollection to `features/<class>.geojson.gz`; returns the .gz path."""
function write_features(dir::String, class::String, features::Vector)::String
    fdir = joinpath(dir, "features"); mkpath(fdir)
    path = joinpath(fdir, "$class.geojson")
    open(path, "w") do io
        JSON3.write(io, Dict("type" => "FeatureCollection", "features" => features))
    end
    run(`gzip -f $path`)   # → <class>.geojson.gz (removes the plain file)
    return path * ".gz"
end

"""buildings engine: every `building=*` way → a Polygon feature with its raw tags."""
function run_buildings!(ctx::Ctx)
    feats = Any[]
    for (_, w) in ctx.data.ways
        haskey(w.tags, "building") || continue
        coords = resolve_way_coords(w, ctx.data.nodes)
        length(coords) >= 3 || continue
        push!(feats, polygon_feature(coords, w.tags))
    end
    out = write_features(ctx.dir, "buildings", feats)
    @info "Extractor: buildings engine" count=length(feats) out=basename(out)
    return nothing
end

"""GeoJSON LineString feature with raw OSM tags."""
linestring_feature(coords::Vector{Coord}, tags::Dict{String,String}) =
    Dict("type" => "Feature",
         "geometry" => Dict("type" => "LineString", "coordinates" => [lonlat(c) for c in coords]),
         "properties" => tags)

"""GeoJSON Point feature with raw OSM tags."""
point_feature(c::Coord, tags::Dict{String,String}) =
    Dict("type" => "Feature",
         "geometry" => Dict("type" => "Point", "coordinates" => lonlat(c)),
         "properties" => tags)

"""A way is a closed ring (area) when its first and last node refs coincide."""
is_closed(w) = length(w.node_refs) >= 4 && w.node_refs[1] == w.node_refs[end]

"""Emit a feature class from ways matching `keep(tags)`: closed → Polygon, open → LineString."""
function emit_ways!(ctx::Ctx, class::String, keep)
    feats = Any[]
    for (_, w) in ctx.data.ways
        keep(w.tags) || continue
        coords = resolve_way_coords(w, ctx.data.nodes)
        if is_closed(w) && length(coords) >= 3
            push!(feats, polygon_feature(coords, w.tags))
        elseif length(coords) >= 2
            push!(feats, linestring_feature(coords, w.tags))
        end
    end
    @info "Extractor: $class engine" count=length(feats) out=basename(write_features(ctx.dir, class, feats))
    return nothing
end

"""Emit a Point feature class from tagged nodes matching `keep(tags)`."""
function emit_nodes!(ctx::Ctx, class::String, keep)
    feats = Any[]
    for (_, n) in ctx.data.nodes
        isempty(n.tags) && continue
        keep(n.tags) || continue
        push!(feats, point_feature(n.coord, n.tags))
    end
    @info "Extractor: $class engine" count=length(feats) out=basename(write_features(ctx.dir, class, feats))
    return nothing
end

# Tag predicates per neutral class — raw OSM selection, NO domain classification
# (consumers apply their own semantics; we just split the map into reusable layers).
_is_road(t)  = haskey(t, "highway")
_is_rail(t)  = haskey(t, "railway")
_is_water(t) = haskey(t, "waterway") || get(t, "natural", "") == "water" ||
               haskey(t, "water") || get(t, "landuse", "") in ("reservoir", "basin")
const _LANDCOVER_NATURAL = ("wood", "scrub", "wetland", "grassland", "heath")
const _LANDCOVER_LANDUSE = ("forest", "meadow", "grass", "farmland", "orchard", "vineyard", "village_green", "allotment")
const _LANDCOVER_LEISURE = ("park", "pitch", "stadium")
_is_landcover(t) = get(t, "natural", "") in _LANDCOVER_NATURAL ||
                   get(t, "landuse", "") in _LANDCOVER_LANDUSE ||
                   get(t, "leisure", "") in _LANDCOVER_LEISURE
_is_poi(t) = any(k -> haskey(t, k), ("amenity", "shop", "tourism", "historic", "man_made")) ||
             get(t, "natural", "") in ("tree", "peak") ||
             get(t, "railway", "") in ("station", "halt") ||
             get(t, "highway", "") == "street_lamp"
_is_settlement(t) = get(t, "place", "") in ("city", "town", "village", "hamlet")

run_roads!(ctx::Ctx)       = emit_ways!(ctx, "roads", _is_road)
run_rail!(ctx::Ctx)        = emit_ways!(ctx, "rail", _is_rail)
run_water!(ctx::Ctx)       = emit_ways!(ctx, "water", _is_water)
run_landcover!(ctx::Ctx)   = emit_ways!(ctx, "landcover", _is_landcover)
run_pois!(ctx::Ctx)        = emit_nodes!(ctx, "pois", _is_poi)
run_settlements!(ctx::Ctx) = emit_nodes!(ctx, "settlements", _is_settlement)

# render3d engine (port of osm-explorer-2 build_world) lives in its own file.
include("render3d.jl")
# Climate normals for the optional phenology engine in osm-world-viewer.
include("climate.jl")

"""SRTM1 tile paths (as /vsigzip/ vsi paths) whose 1°×1° cells intersect `bb`."""
function tiles_for_bbox(bb::BBox)::Vector{String}
    paths = String[]
    for lat in floor(Int, bb.min_lat):floor(Int, bb.max_lat),
        lon in floor(Int, bb.min_lon):floor(Int, bb.max_lon)
        name = string("N", lpad(lat, 2, '0'), "E", lpad(lon, 3, '0'))
        p = joinpath(SRTM_DIR, "$name.hgt.gz")
        isfile(p) && push!(paths, "/vsigzip/" * p)
    end
    return paths
end

"""
elevation engine: clip the SRTM1 30 m DEM to the cell bbox → `<cell>/elevation.tif`.

Mosaics the intersecting HGT tiles (a region can straddle a 1° boundary) and clips
to the bbox. The source is EPSG:4326 (T1) so the output stays geographic — consumers
sample by lat/lon. Records the grid shape in meta.
"""
function run_elevation!(ctx::Ctx)
    tiles = tiles_for_bbox(ctx.bbox)
    isempty(tiles) && error("no SRTM tiles cover bbox $(ctx.bbox)")
    out = joinpath(ctx.dir, "elevation.tif")
    src = [AG.read(t) for t in tiles]
    bb = ctx.bbox
    # gdalwarp mosaics the tiles and clips to the bbox in one call. -te is the
    # target extent (xmin ymin xmax ymax). Same CRS in/out (EPSG:4326) → no reproj.
    AG.gdalwarp(src, ["-te", string(bb.min_lon), string(bb.min_lat),
                      string(bb.max_lon), string(bb.max_lat), "-of", "GTiff"]; dest=out) do ds
        gt = AG.getgeotransform(ds)
        ctx.extra["elevation"] = Dict("cols" => AG.width(ds), "rows" => AG.height(ds),
                                      "res_deg" => abs(gt[2]), "source" => "SRTM1-30m")
    end
    @info "Extractor: elevation engine" tiles=length(tiles) out=basename(out)
    return nothing
end

"""
    extract(center; extent_m, engines=Symbol[], precision=3, label="") -> cell dir

Lay out the cell, **ACQUIRE** the OSM clip (grow-only), and write `meta.json`.

Grow-only semantics: the cell's center is pinned to the first request's center;
later requests only grow `extent_m`. The cached clip is reused when it already
covers the request (same center, cached extent ≥ requested) — otherwise the region
is re-clipped at the larger extent. Engines are recorded but not yet run (added in
later tasks). Returns the absolute cell directory path.
"""
function extract(center::Coord; extent_m::Real, engines::Vector{Symbol}=Symbol[],
                 precision::Int=3, label::String="")::String
    cell = cell_key(center, precision)
    dir = joinpath(OUTPUT_ROOT, cell)
    mkpath(dir)

    # Grow-only: keep the cell's canonical center; grow extent to cover the request.
    prev = read_meta(dir)
    canon = prev === nothing ? center : Coord(prev.center.lat, prev.center.lon)
    cached_extent = prev === nothing ? 0.0 : Float64(prev.extent_m)
    eff_extent = max(Float64(extent_m), cached_extent)
    eff_label = (isempty(label) && prev !== nothing) ? String(prev.label) : label
    bb = square_bbox(canon, eff_extent)

    # ACQUIRE engine: clip the region from the Poland PBF. Reuse when the cached
    # clip already covers this request (same center + cached extent ≥ requested).
    clip = joinpath(dir, "area.osm.pbf")
    if isfile(clip) && cached_extent >= Float64(extent_m)
        @info "Extractor: ACQUIRE cache hit (clip covers request)" cell=cell cached_extent=cached_extent requested=Float64(extent_m)
    else
        @info "Extractor: ACQUIRE clipping region" cell=cell extent_m=eff_extent
        osmium_extract_bbox(pbf_path(), bb, clip)
    end

    # Run requested engines (deps auto-resolved) over the parsed model.
    extras = Dict{String,Any}()
    if !isempty(engines)
        order = resolve_order(engines)
        ctx = Ctx(dir, parse_cell(dir), bb, canon, eff_extent, eff_label, extras)
        for id in order
            REGISTRY[id].run!(ctx)
        end
    end

    meta = Dict(
        "cell" => cell,
        "slug" => isempty(eff_label) ? cell : slugify(eff_label),
        "center" => Dict("lat" => canon.lat, "lon" => canon.lon),
        "bbox" => Dict("min_lat" => bb.min_lat, "min_lon" => bb.min_lon,
                       "max_lat" => bb.max_lat, "max_lon" => bb.max_lon),
        "extent_m" => eff_extent,
        "label" => eff_label,
        "pbf_date" => pbf_date(),
        "srtm_ver" => SRTM_VERSION,
        "extractor_ver" => EXTRACTOR_VERSION,
        "engines_requested" => String[string(e) for e in engines],
        "engines_present" => present_engines(dir),
    )
    merge!(meta, extras)   # engine-contributed fields (e.g. elevation grid shape)
    open(joinpath(dir, "meta.json"), "w") do io
        JSON3.pretty(io, JSON3.write(meta))
    end
    update_manifest!(meta)
    @info "Extractor: wrote cell" cell=cell dir=dir extent_m=eff_extent
    return dir
end

# ============================================================
# Engine framework (registry + dependency DAG)
# ============================================================
#
# An engine produces one artifact in a cell from the parsed model (+ other engines'
# outputs). Engines declare their dependencies; enabling one auto-pulls its deps in
# topological order. This lets each app request only what it needs:
#   microsim = [:buildings,:roads,:rail,:pois,:settlements]
#   explorer = [:render3d]   (pulls buildings/roads/rail/water/landcover/elevation)
#   cycling  = [:routing]    (pulls roads/landcover/water/pois/settlements/elevation)

"""An extraction engine: an id, its dependency engine ids, and a `run!(ctx)` action."""
struct Engine
    id::Symbol
    deps::Vector{Symbol}
    run!::Function
end

const REGISTRY = Dict{Symbol,Engine}()
register!(e::Engine) = (REGISTRY[e.id] = e)

# Placeholder action for engines whose emit logic lands in a later task. Resolves
# the DAG today; throws if actually run, so nothing silently no-ops.
_todo(name::Symbol) = _ctx -> error("engine :$name not yet implemented")

"""
    resolve_order(enabled) -> Vector{Symbol}

Topologically sort `enabled` engines plus all transitive deps, deps first. Throws
on an unknown engine id or a dependency cycle.
"""
function resolve_order(enabled::Vector{Symbol})::Vector{Symbol}
    order = Symbol[]
    done = Set{Symbol}()
    onstack = Set{Symbol}()
    function visit(id::Symbol)
        id in done && return
        haskey(REGISTRY, id) || error("unknown engine: :$id")
        id in onstack && error("dependency cycle involving :$id")
        push!(onstack, id)
        for d in REGISTRY[id].deps
            visit(d)
        end
        delete!(onstack, id)
        push!(done, id)
        push!(order, id)
    end
    for id in enabled
        visit(id)
    end
    return order
end

# Register the built-in engines (deps wired now; run! filled in later tasks).
function __init__()
    register!(Engine(:buildings, Symbol[], run_buildings!))
    register!(Engine(:roads, Symbol[], run_roads!))
    register!(Engine(:rail, Symbol[], run_rail!))
    register!(Engine(:water, Symbol[], run_water!))
    register!(Engine(:landcover, Symbol[], run_landcover!))
    register!(Engine(:pois, Symbol[], run_pois!))
    register!(Engine(:settlements, Symbol[], run_settlements!))
    register!(Engine(:elevation, Symbol[], run_elevation!))
    register!(Engine(:climate, Symbol[], run_climate!))
    register!(Engine(:basemap, Symbol[], _todo(:basemap)))
    register!(Engine(:render3d, [:buildings, :roads, :rail, :water, :landcover, :elevation, :climate], run_render3d!))
    register!(Engine(:routing, [:roads, :landcover, :water, :pois, :settlements, :elevation], _todo(:routing)))
end

end # module Extractor
