"""
    GeoExtractor

Standalone geo-data extraction package, carved out of `Miasteczko.jl` so that
multiple tools can share one extraction pipeline: a transit microsim, a 3D OSM
viewer, and the cycling route generator.

Given an OSM PBF (+ optional SRTM DEM), it clips a region once and emits a
per-region data bundle (raw `area.osm.pbf` clip + processed GeoJSON feature
layers + elevation raster + `meta.json`) under
`~/projects/llm/output/geo-extracts/<cell>/`.

This is a container module — functionality lives in submodules:

```julia
using GeoExtractor.Geo: Coord, haversine, BBox, SpatialIndex
using GeoExtractor.OSM: extract_settlement, extract_from_osm, ExtractionResult, Building, Road
using GeoExtractor.Extractor          # Extractor.extract(Coord; extent_m, engines, …)
```

# Submodules
- [`GeoExtractor.Geo`](@ref) — coordinates, distances, bounding boxes, spatial indexing
- [`GeoExtractor.OSM`](@ref) — OpenStreetMap PBF/XML extraction pipeline
- [`GeoExtractor.Extractor`](@ref) — purpose-aware region extraction + cache bundles
"""
module GeoExtractor

include("geo/Geo.jl")
include("osm/OSM.jl")
include("extractor/Extractor.jl")

end # module GeoExtractor
