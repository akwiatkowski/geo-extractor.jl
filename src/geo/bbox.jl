# Axis-aligned bounding box in geographic coordinates.
#
# Used for spatial filtering (e.g., "all buildings in this area"),
# viewport queries, and osmium extract bounds.

"""
    BBox(min_lat, min_lon, max_lat, max_lon)

Axis-aligned bounding box in geographic coordinates.

# Fields
- `min_lat::Float64` — southern boundary (degrees)
- `min_lon::Float64` — western boundary (degrees)
- `max_lat::Float64` — northern boundary (degrees)
- `max_lon::Float64` — eastern boundary (degrees)

Throws `ArgumentError` if min > max for either axis.

# Examples
```jldoctest
julia> bb = BBox(52.0, 16.0, 53.0, 17.0)
BBox(52.0, 16.0, 53.0, 17.0)

julia> Coord(52.5, 16.5) in bb
true
```
"""
struct BBox
    min_lat::Float64
    min_lon::Float64
    max_lat::Float64
    max_lon::Float64

    function BBox(min_lat::Real, min_lon::Real, max_lat::Real, max_lon::Real)
        min_lat > max_lat && throw(ArgumentError("min_lat ($min_lat) > max_lat ($max_lat)"))
        min_lon > max_lon && throw(ArgumentError("min_lon ($min_lon) > max_lon ($max_lon)"))
        new(Float64(min_lat), Float64(min_lon), Float64(max_lat), Float64(max_lon))
    end
end

Base.show(io::IO, b::BBox) =
    print(io, "BBox($(b.min_lat), $(b.min_lon), $(b.max_lat), $(b.max_lon))")

"""
    bbox_from_coords(coords) → BBox

Compute the bounding box enclosing all coordinates.
Throws `ArgumentError` if `coords` is empty.

# Examples
```jldoctest
julia> bb = bbox_from_coords([Coord(52.0, 16.5), Coord(52.5, 16.0)])
BBox(52.0, 16.0, 52.5, 16.5)
```
"""
function bbox_from_coords(coords::AbstractVector{Coord})::BBox
    isempty(coords) && throw(ArgumentError("cannot compute bbox from empty coordinates"))
    BBox(
        minimum(c.lat for c in coords),
        minimum(c.lon for c in coords),
        maximum(c.lat for c in coords),
        maximum(c.lon for c in coords),
    )
end

"""
    in(c::Coord, bb::BBox) → Bool

Check if coordinate falls inside the bounding box (edges inclusive).

# Examples
```jldoctest
julia> Coord(52.5, 16.5) in BBox(52.0, 16.0, 53.0, 17.0)
true
```
"""
Base.in(c::Coord, bb::BBox)::Bool =
    bb.min_lat <= c.lat <= bb.max_lat && bb.min_lon <= c.lon <= bb.max_lon

"""
    intersects(a::BBox, b::BBox) → Bool

Check if two bounding boxes overlap (edges touching counts as overlap).
"""
function intersects(a::BBox, b::BBox)::Bool
    a.max_lat < b.min_lat && return false
    a.min_lat > b.max_lat && return false
    a.max_lon < b.min_lon && return false
    a.min_lon > b.max_lon && return false
    return true
end

"""
    center(bb::BBox) → Coord

Return the center point of the bounding box.
"""
center(bb::BBox)::Coord = Coord(
    (bb.min_lat + bb.max_lat) / 2,
    (bb.min_lon + bb.max_lon) / 2,
)

"""
    expand_bbox(bb::BBox, margin_m::Real) → BBox

Expand bounding box by `margin_m` meters in all four directions.
Uses equirectangular approximation at the box center latitude.

# Examples
```jldoctest
julia> bb = BBox(52.0, 16.0, 52.1, 16.1);

julia> expanded = expand_bbox(bb, 1000.0);

julia> expanded.min_lat < bb.min_lat
true
```
"""
function expand_bbox(bb::BBox, margin_m::Real)::BBox
    c = center(bb)
    dlat = Float64(margin_m) / (DEG_TO_RAD * EARTH_RADIUS_M)
    dlon = Float64(margin_m) / (DEG_TO_RAD * EARTH_RADIUS_M * cos(c.lat * DEG_TO_RAD))
    BBox(bb.min_lat - dlat, bb.min_lon - dlon, bb.max_lat + dlat, bb.max_lon + dlon)
end

"""
    width_m(bb::BBox) → Float64

Approximate east-west width of the bounding box in meters.
Computed at the center latitude.
"""
function width_m(bb::BBox)::Float64
    c = center(bb)
    (bb.max_lon - bb.min_lon) * DEG_TO_RAD * EARTH_RADIUS_M * cos(c.lat * DEG_TO_RAD)
end

"""
    height_m(bb::BBox) → Float64

Approximate north-south height of the bounding box in meters.
"""
height_m(bb::BBox)::Float64 =
    (bb.max_lat - bb.min_lat) * DEG_TO_RAD * EARTH_RADIUS_M
