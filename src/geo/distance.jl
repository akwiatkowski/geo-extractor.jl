# Distance calculations between geographic coordinates.
#
# Two levels of accuracy:
# - haversine: great-circle distance, accurate globally (~0.3% vs ellipsoid)
# - to_meters/from_meters: equirectangular projection, fast, accurate <100 km

"""Earth mean radius in meters (WGS84 standard)."""
const EARTH_RADIUS_M = 6_371_000.0

"""Conversion factor: degrees to radians."""
const DEG_TO_RAD = π / 180.0

"""
    haversine(a::Coord, b::Coord) → Float64

Great-circle distance between two coordinates in **meters**.

Uses the Haversine formula with spherical Earth model (R = 6,371 km).
Accurate to ~0.3% vs WGS84 ellipsoid. For distances under 1000 km,
error is typically <0.1%.

# Examples
```jldoctest
julia> poznan = Coord(52.4064, 16.9252);

julia> warszawa = Coord(52.2297, 21.0122);

julia> d = haversine(poznan, warszawa);

julia> 275_000 < d < 282_000  # ~278 km
true
```
"""
function haversine(a::Coord, b::Coord)::Float64
    φ1 = a.lat * DEG_TO_RAD
    φ2 = b.lat * DEG_TO_RAD
    Δφ = (b.lat - a.lat) * DEG_TO_RAD
    Δλ = (b.lon - a.lon) * DEG_TO_RAD

    # Haversine formula: numerically stable for small distances
    h = sin(Δφ / 2)^2 + cos(φ1) * cos(φ2) * sin(Δλ / 2)^2
    return 2 * EARTH_RADIUS_M * asin(min(1.0, sqrt(h)))
end

"""
    haversine_km(a::Coord, b::Coord) → Float64

Great-circle distance between two coordinates in **kilometers**.

Convenience wrapper around [`haversine`](@ref) for when you need km.

# Examples
```jldoctest
julia> poznan = Coord(52.4064, 16.9252);

julia> warszawa = Coord(52.2297, 21.0122);

julia> d = haversine_km(poznan, warszawa);

julia> 275 < d < 282  # ~278 km
true
```
"""
haversine_km(a::Coord, b::Coord)::Float64 = haversine(a, b) / 1000.0

"""
    to_meters(c::Coord, ref::Coord) → (x=Float64, y=Float64)

Convert geographic coordinate to local meters `(x=east, y=north)`
relative to a reference point, using equirectangular projection.

Accurate within ~100 km of the reference point.
Error grows with distance: ~0.3% at 100 km, ~1% at 300 km.

The returned NamedTuple supports both named access (`m.x`, `m.y`)
and destructuring (`x, y = to_meters(...)`).

# Examples
```jldoctest
julia> ref = Coord(52.0, 17.0);

julia> m = to_meters(Coord(52.009, 17.0), ref);

julia> abs(m.x) < 1.0 && 990 < m.y < 1010  # ~1 km north
true
```
"""
function to_meters(c::Coord, ref::Coord)
    x = (c.lon - ref.lon) * DEG_TO_RAD * EARTH_RADIUS_M * cos(ref.lat * DEG_TO_RAD)
    y = (c.lat - ref.lat) * DEG_TO_RAD * EARTH_RADIUS_M
    return (x=x, y=y)
end

"""
    from_meters(x, y, ref::Coord) → Coord

Convert local meters `(x=east, y=north)` back to geographic coordinate.
Inverse of [`to_meters`](@ref).

# Examples
```jldoctest
julia> ref = Coord(52.0, 17.0);

julia> p = from_meters(0.0, 1000.0, ref);  # 1 km north

julia> p.lon ≈ 17.0
true
```
"""
function from_meters(x::Real, y::Real, ref::Coord)::Coord
    lat = ref.lat + Float64(y) / (DEG_TO_RAD * EARTH_RADIUS_M)
    lon = ref.lon + Float64(x) / (DEG_TO_RAD * EARTH_RADIUS_M * cos(ref.lat * DEG_TO_RAD))
    return Coord(lat, lon)
end
