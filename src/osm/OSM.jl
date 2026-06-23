"""
    GeoExtractor.OSM

OpenStreetMap data extraction pipeline.

Extract and parse settlement data from OSM PBF files via osmium.
Produces typed Julia structs for buildings, roads, POIs, natural features, rail.

# Usage
```julia
using GeoExtractor.OSM: extract_settlement, extract_from_osm, ExtractionResult
using GeoExtractor.OSM: Building, Road, POI, Settlement, BuildingType
using GeoExtractor.OSM: buildings_to_geojson, roads_to_geojson, save_geojson
```
"""
module OSM

using ..Geo  # import sibling submodule

include("types.jl")
include("geometry.jl")
include("classify.jl")
include("osmium.jl")
include("xml_parser.jl")
include("buildings.jl")
include("roads.jl")
include("pois.jl")
include("natural.jl")
include("rail.jl")
include("settlement.jl")
include("extract.jl")
include("serialize.jl")

# BuildingType enum
export BuildingType
export RESIDENTIAL_HOUSE, RESIDENTIAL_APARTMENT, COMMERCIAL_SHOP, COMMERCIAL_OFFICE
export INDUSTRIAL, EDUCATION, HEALTHCARE, PUBLIC, RELIGIOUS, OTHER

# OSM data types
export Building, Road, POI, Settlement, RailStation, RailSegment, NaturalFeature

# OSM geometry
export polygon_area_m2, polygon_centroid, make_square_polygon

# OSM classification
export classify_building_type, estimate_capacity, classify_poi

# Osmium CLI wrapper
export check_osmium, osmium_extract_polygon, osmium_extract_bbox, osmium_tags_filter

# OSM XML parser
export OsmData, parse_osm_xml, resolve_way_coords

# OSM extraction
export extract_buildings, extract_roads, extract_pois
export extract_natural_features
export extract_rail_stations, extract_rail_segments
export find_settlements, find_settlement, slugify

# High-level extraction
export ExtractionResult, extract_from_osm, extract_settlement

# Serialization
export buildings_to_geojson, roads_to_geojson, pois_to_geojson
export natural_to_geojson, rail_to_geojson, settlements_to_geojson
export to_json_string, save_geojson
export save_buildings_json, load_buildings_json

end # module OSM
