# GeoExtractor.jl

Standalone geo-data extraction package, carved out of
[`Miasteczko.jl`](../urban/miasteczko-jl) so several tools can share one
extraction pipeline: the transit microsim, a 3D OSM viewer, and the cycling
route generator.

Given an OSM PBF (+ optional SRTM DEM), it clips a region **once** and emits a
per-region bundle — raw `area.osm.pbf` clip, processed GeoJSON feature layers
(roads, buildings, water, landcover, rail, POIs, settlements), an elevation
raster, and `meta.json` — under `~/projects/llm/output/geo-extracts/<cell>/`.
Extraction is **grow-only**: a request whose bbox fits inside a cached cell is a
hit; otherwise the cell is re-extracted at the larger extent.

## Modules

```julia
using GeoExtractor.Geo: Coord, haversine, BBox, SpatialIndex
using GeoExtractor.OSM: extract_settlement, extract_from_osm, ExtractionResult, Building, Road
using GeoExtractor.Extractor          # Extractor.extract(Coord; extent_m, engines, …)
```

- **`Geo`** — coordinates, distances, bounding boxes, spatial indexing (standalone).
- **`OSM`** — OpenStreetMap PBF/XML extraction pipeline (depends on `Geo`).
- **`Extractor`** — purpose-aware region extraction + on-disk cache bundles
  (depends on `Geo` + `OSM`).

## Requirements

- Julia ≥ 1.10 (managed via `mise`; run commands as `mise exec -- julia …`).
- [`osmium-tool`](https://osmcode.org/osmium-tool/) on `PATH` for PBF clipping.
- `LLM_OSM` env var pointing at the dir holding `poland-latest.osm.pbf`.
- SRTM1 HGT tiles under `~/projects/llm/input/srtm/` for the elevation engine.

## Develop / test

```bash
mise exec -- julia --project=. -e 'using Pkg; Pkg.instantiate()'
mise exec -- julia --project=. -e 'using Pkg; Pkg.test()'
```

## Status

Carved out 2026-06-23. Consumers (`Miasteczko.jl`, cycling route generator) still
need to be rewired to depend on this package — see
`~/projects/claude/plans/cycle-router.md`.
