"""
    GeoExtractor.Geo

Spatial foundations: coordinates, distances, bounding boxes, spatial indexing.

# Usage
```julia
using GeoExtractor.Geo: Coord, haversine, BBox, SpatialIndex
using GeoExtractor.Geo: coord_from_lonlat, to_meters, from_meters
using GeoExtractor.Geo: bbox_from_coords, expand_bbox, find_nearest, find_within_radius
```
"""
module Geo

include("coord.jl")
include("distance.jl")
include("bbox.jl")
include("spatial_index.jl")

# Coord
export Coord, coord_from_lonlat, coord_from_geojson
export to_lonlat_vec, to_lonlat_tuple

# Distance
export haversine, haversine_km, to_meters, from_meters
export EARTH_RADIUS_M, DEG_TO_RAD

# BBox
export BBox, bbox_from_coords
export intersects, expand_bbox, center
export width_m, height_m

# SpatialIndex
export SpatialIndex, find_nearest, find_nearest_idx_dist, find_within_radius

end # module Geo
