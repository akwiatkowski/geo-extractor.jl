# Wrapper for the osmium CLI tool (osmium-tool).
#
# Osmium handles heavy PBF extraction — filtering by polygon/bbox and tag.
# Julia handles parsing the small extracted results.
# Install: brew install osmium-tool

# Cached result of osmium availability check
const _osmium_available = Ref{Union{Bool,Nothing}}(nothing)

"""
    check_osmium() → Bool

Check if the `osmium` CLI tool is installed and accessible.
Result is cached after the first call.

# Examples
```julia
check_osmium() || error("Install osmium: brew install osmium-tool")
```
"""
function check_osmium()::Bool
    if _osmium_available[] === nothing
        try
            result = read(`osmium --version`, String)
            _osmium_available[] = contains(result, "osmium")
        catch
            _osmium_available[] = false
        end
    end
    return _osmium_available[]::Bool
end

function _require_osmium()
    check_osmium() || error(
        "osmium CLI not found. Install it:\n" *
        "  macOS:  brew install osmium-tool\n" *
        "  Ubuntu: apt install osmium-tool\n" *
        "  Arch:   pacman -S osmium-tool"
    )
end

"""
    _osmium_bbox_string(bb::BBox) → String

Format BBox as osmium bbox string: "min_lon,min_lat,max_lon,max_lat".
"""
_osmium_bbox_string(bb::BBox)::String =
    "$(bb.min_lon),$(bb.min_lat),$(bb.max_lon),$(bb.max_lat)"

"""
    _write_polygon_geojson(polygon::Vector{Coord}, path::String)

Write a polygon as a GeoJSON file for use with osmium extract --polygon.
Coordinates are in GeoJSON [lon, lat] order. The polygon ring is closed.
"""
function _write_polygon_geojson(polygon::Vector{Coord}, path::String)
    # Build coordinate array in [lon, lat] order, with ring closed
    coords = [to_lonlat_vec(c) for c in polygon]
    # Close the ring if not already closed
    if length(coords) > 0 && coords[1] != coords[end]
        push!(coords, coords[1])
    end

    # Write minimal GeoJSON — osmium only needs geometry
    geojson = Dict(
        "type" => "Feature",
        "geometry" => Dict(
            "type" => "Polygon",
            "coordinates" => [coords],
        ),
        "properties" => Dict{String,Any}(),
    )

    open(path, "w") do io
        # Simple JSON serialization without external dependency
        _write_json(io, geojson)
    end
end

# Minimal JSON writer for GeoJSON output (avoids JSON3 dependency for osmium module)
function _write_json(io::IO, d::Dict)
    print(io, "{")
    first = true
    for (k, v) in d
        first || print(io, ",")
        first = false
        print(io, "\"$k\":")
        _write_json(io, v)
    end
    print(io, "}")
end
function _write_json(io::IO, v::Vector)
    print(io, "[")
    for (i, item) in enumerate(v)
        i > 1 && print(io, ",")
        _write_json(io, item)
    end
    print(io, "]")
end
_write_json(io::IO, s::String) = print(io, "\"", s, "\"")
_write_json(io::IO, n::Number) = print(io, n)
_write_json(io::IO, ::Nothing) = print(io, "null")

"""
    osmium_extract_polygon(pbf::String, polygon::Vector{Coord}, output::String;
                           buffer_m::Real=0, overwrite::Bool=true)

Extract an area from a PBF file using a polygon boundary.

Optionally buffers the polygon by `buffer_m` meters before extraction.
Calls: `osmium extract --polygon <geojson> <pbf> -o <output>`

# Arguments
- `pbf` — path to input PBF file
- `polygon` — boundary polygon as Vector{Coord}
- `output` — path for output file (.osm or .pbf)
- `buffer_m` — expand polygon by this many meters (default: 0)
- `overwrite` — overwrite output if exists (default: true)
"""
function osmium_extract_polygon(pbf::String, polygon::Vector{Coord}, output::String;
                                 buffer_m::Real=0, overwrite::Bool=true)
    _require_osmium()
    isfile(pbf) || error("PBF file not found: $pbf")

    # Optionally buffer the polygon
    actual_polygon = if buffer_m > 0
        _buffer_polygon(polygon, Float64(buffer_m))
    else
        polygon
    end

    # Write polygon to temporary GeoJSON
    tmpfile = tempname() * ".geojson"
    try
        _write_polygon_geojson(actual_polygon, tmpfile)
        cmd = `osmium extract --polygon $tmpfile $pbf -o $output`
        if overwrite
            cmd = `osmium extract --polygon $tmpfile $pbf -o $output --overwrite`
        end
        run(cmd)
    finally
        isfile(tmpfile) && rm(tmpfile)
    end
end

"""
    osmium_extract_bbox(pbf::String, bbox::BBox, output::String; overwrite::Bool=true)

Extract an area from a PBF file using a bounding box.

Calls: `osmium extract --bbox <bbox> <pbf> -o <output>`
"""
function osmium_extract_bbox(pbf::String, bbox::BBox, output::String;
                              overwrite::Bool=true)
    _require_osmium()
    isfile(pbf) || error("PBF file not found: $pbf")

    bbox_str = _osmium_bbox_string(bbox)
    cmd = if overwrite
        `osmium extract --bbox $bbox_str $pbf -o $output --overwrite`
    else
        `osmium extract --bbox $bbox_str $pbf -o $output`
    end
    run(cmd)
end

"""
    osmium_tags_filter(pbf::String, tags::Vector{String}, output::String;
                       overwrite::Bool=true)

Filter a PBF file by OSM tags.

Tags follow osmium syntax: `"n/place=city,town"`, `"w/highway=residential"`,
`"r/boundary=administrative"`.

Calls: `osmium tags-filter <pbf> <tags...> -o <output>`
"""
function osmium_tags_filter(pbf::String, tags::Vector{String}, output::String;
                             overwrite::Bool=true)
    _require_osmium()
    isfile(pbf) || error("PBF file not found: $pbf")

    cmd = if overwrite
        `osmium tags-filter $pbf $tags -o $output --overwrite`
    else
        `osmium tags-filter $pbf $tags -o $output`
    end
    run(cmd)
end

# ── Polygon buffering ────────────────────────────────────────────────

# Simple polygon buffer: scale each vertex outward from centroid
function _buffer_polygon(polygon::Vector{Coord}, buffer_m::Float64)::Vector{Coord}
    c = polygon_centroid(polygon)
    buffered = Coord[]
    for v in polygon
        m = to_meters(v, c)
        dist = sqrt(m.x^2 + m.y^2)
        if dist < 1.0
            push!(buffered, v)
            continue
        end
        scale = (dist + buffer_m) / dist
        new_x = m.x * scale
        new_y = m.y * scale
        push!(buffered, from_meters(new_x, new_y, c))
    end
    return buffered
end
