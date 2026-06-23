# Geographic coordinate type and conversions between lat/lon and GeoJSON orders.
#
# The fundamental spatial primitive. All other geo types build on Coord.
# GeoJSON uses [lon, lat] order; geographic convention is (lat, lon).
# This module provides explicit conversions to avoid the common mixup.

"""
    Coord(lat, lon)

Geographic coordinate in WGS84 (latitude, longitude in degrees).

# Fields
- `lat::Float64` — latitude in degrees (north positive, −90 to 90)
- `lon::Float64` — longitude in degrees (east positive, −180 to 180)

# Coordinate order
Constructor uses `(lat, lon)` — geographic convention.
GeoJSON uses `[lon, lat]` — use [`coord_from_lonlat`](@ref) or
[`coord_from_geojson`](@ref) when reading GeoJSON data.

# Examples
```jldoctest
julia> c = Coord(52.4064, 16.9252)  # Poznan, Poland
Coord(52.4064, 16.9252)

julia> c.lat
52.4064
```
"""
struct Coord
    lat::Float64
    lon::Float64
end

"""
    coord_from_lonlat(lon, lat) → Coord

Create a Coord from `(lon, lat)` order, as used in GeoJSON coordinates.

# Examples
```jldoctest
julia> c = coord_from_lonlat(16.9252, 52.4064)
Coord(52.4064, 16.9252)
```
"""
coord_from_lonlat(lon::Real, lat::Real)::Coord = Coord(Float64(lat), Float64(lon))

"""
    coord_from_geojson(arr) → Coord

Create a Coord from a GeoJSON coordinate array `[lon, lat]`.

# Examples
```jldoctest
julia> coord_from_geojson([16.9252, 52.4064])
Coord(52.4064, 16.9252)
```
"""
coord_from_geojson(arr)::Coord = Coord(Float64(arr[2]), Float64(arr[1]))

"""
    to_lonlat_vec(c::Coord) → Vector{Float64}

Convert to `[lon, lat]` vector for GeoJSON serialization.

# Examples
```jldoctest
julia> to_lonlat_vec(Coord(52.4064, 16.9252))
2-element Vector{Float64}:
 16.9252
 52.4064
```
"""
to_lonlat_vec(c::Coord)::Vector{Float64} = [c.lon, c.lat]

"""
    to_lonlat_tuple(c::Coord) → Tuple{Float64, Float64}

Convert to `(lon, lat)` tuple for GeoJSON or Leaflet interop.
"""
to_lonlat_tuple(c::Coord)::Tuple{Float64, Float64} = (c.lon, c.lat)

# ── Base method extensions ───────────────────────────────────────────

Base.isapprox(a::Coord, b::Coord; kwargs...) =
    isapprox(a.lat, b.lat; kwargs...) && isapprox(a.lon, b.lon; kwargs...)

Base.show(io::IO, c::Coord) = print(io, "Coord($(c.lat), $(c.lon))")
