using Test
using GeoExtractor
using GeoExtractor.Geo: Coord, haversine, haversine_km, BBox, bbox_from_coords, expand_bbox

@testset "GeoExtractor loads" begin
    # The three submodules are wired up.
    @test isdefined(GeoExtractor, :Geo)
    @test isdefined(GeoExtractor, :OSM)
    @test isdefined(GeoExtractor, :Extractor)
end

@testset "Geo basics" begin
    poznan = Coord(52.4064, 16.9252)
    warszawa = Coord(52.2297, 21.0122)

    # Distance to self is zero; distance between two points is positive.
    @test haversine(poznan, poznan) == 0.0
    @test haversine(poznan, warszawa) > 0.0

    # Poznań–Warszawa straight-line is ~279 km (allow generous tolerance).
    @test isapprox(haversine_km(poznan, warszawa), 279.0; atol = 15.0)

    # A bbox over both points contains both.
    bb = bbox_from_coords([poznan, warszawa])
    @test bb.min_lat <= poznan.lat <= bb.max_lat
    @test bb.min_lon <= warszawa.lon <= bb.max_lon
end
