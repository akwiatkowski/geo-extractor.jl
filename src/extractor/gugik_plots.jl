# GUGiK cadastral plot borders (granice działek) loader + downloader.
#
# Source/cache: ~/projects/llm/input/gugik/<lat>_<lon>.txt files.
# Each file contains one ULDK response line:
#   0
#   SRID=4326;POLYGON((lon lat, ...))|300208_5.0017.323
#
# The downloader queries the free GUGiK ULDK point service once per building
# plot (grid-deduped), so we get the real parcel that contains each building.
# Fetching is opt-in via the GUGIK_DOWNLOAD environment variable so normal
# extraction stays fully offline; the loader always reads whatever is cached.

import HTTP
using Printf: @sprintf

const GUGIK_PLOTS_DIR = joinpath(homedir(), "projects", "llm", "input", "gugik")
const ULDK_URL = "https://uldk.gugik.gov.pl/"
const ULDK_PAUSE_S = 0.12  # polite delay between live (uncached) requests
const GUGIK_DEDUP_CELL_DEG = 0.00008  # ≈ 8.9 m lat / 5.5 m lon at 52°N
const GUGIK_USER_AGENT = "osm-world-viewer/1.0"

"""
    gugik_cache_path(lat, lon) -> String

Cache filename matching the old Python extractor: five-decimal fixed point,
underscore-separated, `.txt` extension.
"""
gugik_cache_path(lat::Real, lon::Real) =
    joinpath(GUGIK_PLOTS_DIR, @sprintf("%.5f_%.5f.txt", lat, lon))

"""
    parse_wkt_polygon(wkt::String) -> Vector{Coord}

Parse the first ring of a ULDK geometry response. Handles simple `POLYGON`,
`POLYGON` with holes, and `MULTIPOLYGON` by extracting the first parenthesised
run of coordinate text. Returns the exterior ring as `Coord`s (lat, lon).
"""
function parse_wkt_polygon(wkt::AbstractString)::Vector{Coord}
    m = match(r"\(([-0-9eE\.\,\s]+)\)", wkt)
    m === nothing && return Coord[]
    coords = Coord[]
    for pair in split(m.captures[1], ',')
        parts = split(strip(pair))
        length(parts) < 2 && continue
        lon = parse(Float64, parts[1])
        lat = parse(Float64, parts[2])
        push!(coords, Coord(lat, lon))
    end
    return coords
end

"""
    load_gugik_plots(bb::BBox) -> Vector{Tuple{Vector{Coord}, String}}

Load cached GUGiK plot borders whose filename centroid falls inside `bb`.
Returns `(ring, id)` tuples. Empty if the cache directory is missing.
"""
function load_gugik_plots(bb::BBox)::Vector{Tuple{Vector{Coord}, String}}
    isdir(GUGIK_PLOTS_DIR) || return Tuple{Vector{Coord}, String}[]
    plots = Tuple{Vector{Coord}, String}[]
    for fname in readdir(GUGIK_PLOTS_DIR)
        endswith(fname, ".txt") || continue
        m = match(r"^([-+]?\d+\.\d+)_([-+]?\d+\.\d+)\.txt$", fname)
        m === nothing && continue
        lat = parse(Float64, m.captures[1])
        lon = parse(Float64, m.captures[2])
        (bb.min_lat <= lat <= bb.max_lat && bb.min_lon <= lon <= bb.max_lon) || continue

        path = joinpath(GUGIK_PLOTS_DIR, fname)
        lines = readlines(path)
        length(lines) < 2 && continue
        wkt_line = lines[2]
        parts = split(wkt_line, '|')
        wkt = strip(parts[1])
        id = length(parts) >= 2 ? strip(parts[2]) : ""

        ring = parse_wkt_polygon(wkt)
        length(ring) >= 3 || continue
        push!(plots, (ring, id))
    end
    return plots
end

"""
    uldk_fetch(lat, lon) -> Union{String, Nothing}

Fetch the raw ULDK response for the parcel containing `(lat, lon)`. Returns
`nothing` on network failure or non-200 response. Successful responses are
*not* cached here; callers decide whether to write the cache file.
"""
function uldk_fetch(lat::Real, lon::Real)::Union{String, Nothing}
    url = ULDK_URL
    query = Dict(
        "request" => "GetParcelByXY",
        "xy" => "$(lon),$(lat),4326",
        "result" => "geom_wkt,id",
        "srid" => "4326",
    )
    headers = Dict("User-Agent" => GUGIK_USER_AGENT)
    try
        resp = HTTP.get(url; query=query, headers=headers, readtimeout=20, status_exception=false)
        resp.status == 200 || return nothing
        return String(resp.body)
    catch e
        @warn "ULDK fetch failed" lat lon exception=e
        return nothing
    end
end

"""
    download_gugik_plots!(building_footprints::Vector{Vector{Coord}};
                          force::Bool=false,
                          max_buildings::Int=500,
                          pause::Real=ULDK_PAUSE_S) -> Int

Query the GUGiK ULDK service for the cadastral parcel under each building
footprint, cache the responses, and return the number of new cache files
written.

Buildings in the same real-world plot share a parcel, so centroids are
grid-deduped before querying to avoid redundant requests. A hard ceiling on
building count prevents accidental hour-long runs for huge tiles; pass
`max_buildings=typemax(Int)` to override.

Set `force=true` to re-fetch points that are already cached (useful when the
upstream data changed). The function is a no-op unless the `GUGIK_DOWNLOAD`
environment variable is set to `"1"`/`"true"`, so plain extraction remains
offline.
"""
function download_gugik_plots!(building_footprints::Vector{Vector{Coord}};
                               force::Bool=false,
                               max_buildings::Int=500,
                               pause::Real=ULDK_PAUSE_S)::Int
    env = lowercase(strip(get(ENV, "GUGIK_DOWNLOAD", "")))
    (env == "1" || env == "true") || return 0

    isdir(GUGIK_PLOTS_DIR) || mkpath(GUGIK_PLOTS_DIR)

    # Centroid of each footprint.
    centroids = Coord[]
    for fp in building_footprints
        length(fp) < 3 && continue
        lat = sum(c.lat for c in fp) / length(fp)
        lon = sum(c.lon for c in fp) / length(fp)
        push!(centroids, Coord(lat, lon))
    end

    if length(centroids) > max_buildings
        @warn "GUGiK download skipped: too many buildings" count=length(centroids) max=max_buildings
        return 0
    end

    # Dedup to a coarse grid: one query per occupied cell.
    seen = Set{Tuple{Int, Int}}()
    points = Coord[]
    for c in centroids
        key = (round(Int, c.lat / GUGIK_DEDUP_CELL_DEG), round(Int, c.lon / GUGIK_DEDUP_CELL_DEG))
        key in seen && continue
        push!(seen, key)
        push!(points, c)
    end

    written = 0
    total = length(points)
    @info "GUGiK: downloading parcels" buildings=length(centroids) queries=total cache=GUGIK_PLOTS_DIR
    for (i, c) in enumerate(points)
        path = gugik_cache_path(c.lat, c.lon)
        if !force && isfile(path)
            continue
        end
        text = uldk_fetch(c.lat, c.lon)
        text === nothing && continue
        if startswith(strip(text), "0")
            write(path, text)
            written += 1
        end
        sleep(pause)
        @debug "GUGiK: progress" i=i total=total written=written
    end
    @info "GUGiK: done" queries=total written=written
    return written
end
