# Geometric calculations for OSM polygon data.
#
# Area via Shoelace formula with equirectangular projection.
# Centroid via simple vertex mean.
# Square polygon generation for point POIs that need a footprint.

"""
    polygon_area_m2(polygon::Vector{Coord}) → Float64

Compute the area of a geographic polygon in square meters.

Uses the Shoelace formula with equirectangular projection centered on the
polygon centroid. Accurate for polygons under ~10 km across.

Returns 0.0 for degenerate polygons (fewer than 3 vertices).

# Examples
```julia
# A roughly 100m x 100m rectangle at 52N
polygon = [Coord(52.0, 17.0), Coord(52.0, 17.00145),
           Coord(52.0009, 17.00145), Coord(52.0009, 17.0)]
polygon_area_m2(polygon)  # ≈ 10000.0
```
"""
function polygon_area_m2(polygon::Vector{Coord})::Float64
    n = length(polygon)
    n < 3 && return 0.0

    # Project to meters using centroid as reference
    c = polygon_centroid(polygon)
    cos_lat = cos(c.lat * DEG_TO_RAD)
    mx = DEG_TO_RAD * EARTH_RADIUS_M * cos_lat   # meters per degree longitude
    my = DEG_TO_RAD * EARTH_RADIUS_M              # meters per degree latitude

    # Shoelace formula in projected coordinates
    area = 0.0
    for i in 1:n
        j = mod1(i + 1, n)
        xi = polygon[i].lon * mx
        yi = polygon[i].lat * my
        xj = polygon[j].lon * mx
        yj = polygon[j].lat * my
        area += xi * yj - xj * yi
    end
    return abs(area) / 2.0
end

"""
    polygon_centroid(polygon::Vector{Coord}) → Coord

Compute the centroid (mean of vertices) of a polygon.

This is the arithmetic mean, not the area-weighted centroid.
Accurate enough for convex and near-convex building footprints.
"""
function polygon_centroid(polygon::Vector{Coord})::Coord
    n = length(polygon)
    n == 0 && return Coord(0.0, 0.0)
    lat = sum(c.lat for c in polygon) / n
    lon = sum(c.lon for c in polygon) / n
    return Coord(lat, lon)
end

"""
    make_square_polygon(center::Coord, side_m::Float64) → Vector{Coord}

Generate a 4-vertex square polygon centered at `center` with given side length in meters.

Used to create synthetic footprints for point POIs that have no polygon geometry.
The square is axis-aligned (not rotated).

# Examples
```julia
sq = make_square_polygon(Coord(52.0, 17.0), 10.0)  # 10m square
length(sq)  # 4
```
"""
function make_square_polygon(center::Coord, side_m::Float64)::Vector{Coord}
    half = side_m / 2.0
    cos_lat = cos(center.lat * DEG_TO_RAD)
    d_lon = half / (DEG_TO_RAD * EARTH_RADIUS_M * cos_lat)
    d_lat = half / (DEG_TO_RAD * EARTH_RADIUS_M)
    return [
        Coord(center.lat - d_lat, center.lon - d_lon),  # SW
        Coord(center.lat - d_lat, center.lon + d_lon),  # SE
        Coord(center.lat + d_lat, center.lon + d_lon),  # NE
        Coord(center.lat + d_lat, center.lon - d_lon),  # NW
    ]
end
