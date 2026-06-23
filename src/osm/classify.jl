# OSM tag classification tables and capacity estimation.
#
# Maps OSM tags to BuildingType enum values and estimates person capacity.
# Classification priority: amenity > shop/office > tourism > building tag.
# Tables are module-level Dicts — easy to extend or override.
#
# Ported from people-sim buildings.jl with same classification logic.

# ── Building classification ──────────────────────────────────────────

# Amenity tag → BuildingType (highest priority)
const AMENITY_TO_BUILDING_TYPE = Dict{String,BuildingType}(
    # Education
    "school"            => EDUCATION,
    "kindergarten"      => EDUCATION,
    "university"        => EDUCATION,
    "college"           => EDUCATION,
    "library"           => EDUCATION,
    # Healthcare
    "hospital"          => HEALTHCARE,
    "clinic"            => HEALTHCARE,
    "doctors"           => HEALTHCARE,
    "dentist"           => HEALTHCARE,
    "pharmacy"          => HEALTHCARE,
    "veterinary"        => HEALTHCARE,
    # Public
    "townhall"          => PUBLIC,
    "community_centre"  => PUBLIC,
    "fire_station"      => PUBLIC,
    "police"            => PUBLIC,
    "post_office"       => PUBLIC,
    "social_facility"   => PUBLIC,
    # Religious
    "place_of_worship"  => RELIGIOUS,
    # Commercial
    "cafe"              => COMMERCIAL_SHOP,
    "restaurant"        => COMMERCIAL_SHOP,
    "bar"               => COMMERCIAL_SHOP,
    "pub"               => COMMERCIAL_SHOP,
    "fast_food"         => COMMERCIAL_SHOP,
    "fuel"              => COMMERCIAL_SHOP,
    "bank"              => COMMERCIAL_SHOP,
    "atm"               => COMMERCIAL_SHOP,
)

# Tourism tag values that map to COMMERCIAL_SHOP
const TOURISM_COMMERCIAL = Set(["hotel", "motel", "hostel", "guest_house"])

# Building tag → BuildingType (lowest priority, used when no amenity/shop/office/tourism)
const BUILDING_TAG_TO_TYPE = Dict{String,BuildingType}(
    # Residential houses
    "house"               => RESIDENTIAL_HOUSE,
    "detached"            => RESIDENTIAL_HOUSE,
    "semidetached_house"  => RESIDENTIAL_HOUSE,
    "terrace"             => RESIDENTIAL_HOUSE,
    "farm"                => RESIDENTIAL_HOUSE,
    "bungalow"            => RESIDENTIAL_HOUSE,
    "cabin"               => RESIDENTIAL_HOUSE,
    "static_caravan"      => RESIDENTIAL_HOUSE,
    # Apartments
    "apartments"          => RESIDENTIAL_APARTMENT,
    "residential"         => RESIDENTIAL_APARTMENT,
    "dormitory"           => RESIDENTIAL_APARTMENT,
    "hotel"               => RESIDENTIAL_APARTMENT,
    # Commercial
    "retail"              => COMMERCIAL_SHOP,
    "commercial"          => COMMERCIAL_SHOP,
    "supermarket"         => COMMERCIAL_SHOP,
    "kiosk"               => COMMERCIAL_SHOP,
    # Office
    "office"              => COMMERCIAL_OFFICE,
    # Industrial
    "industrial"          => INDUSTRIAL,
    "warehouse"           => INDUSTRIAL,
    "manufacture"         => INDUSTRIAL,
    "hangar"              => INDUSTRIAL,
    # Education
    "school"              => EDUCATION,
    "university"          => EDUCATION,
    "kindergarten"        => EDUCATION,
    # Healthcare
    "hospital"            => HEALTHCARE,
    "clinic"              => HEALTHCARE,
    # Religious
    "church"              => RELIGIOUS,
    "chapel"              => RELIGIOUS,
    "cathedral"           => RELIGIOUS,
    "mosque"              => RELIGIOUS,
    "synagogue"           => RELIGIOUS,
    "temple"              => RELIGIOUS,
    # Public
    "civic"               => PUBLIC,
    "government"          => PUBLIC,
    "public"              => PUBLIC,
    "fire_station"        => PUBLIC,
    "train_station"       => PUBLIC,
    "transportation"      => PUBLIC,
    # Default: building=yes → house (most common in small Polish towns)
    "yes"                 => RESIDENTIAL_HOUSE,
)

"""
    classify_building_type(tags::Dict{String,String}) → BuildingType

Classify a building by its OSM tags.

Priority order:
1. `amenity` tag (schools, hospitals, shops, churches...)
2. `shop` tag → COMMERCIAL_SHOP
3. `office` tag → COMMERCIAL_OFFICE
4. `tourism` tag (hotels, hostels...)
5. `building` tag (house, apartments, industrial...)
6. Default → OTHER

# Examples
```julia
classify_building_type(Dict("building" => "yes", "amenity" => "school"))
# → EDUCATION (amenity overrides building tag)
```
"""
function classify_building_type(tags::Dict{String,String})::BuildingType
    # Priority 1: amenity tag
    amenity = get(tags, "amenity", "")
    if !isempty(amenity)
        bt = get(AMENITY_TO_BUILDING_TYPE, amenity, nothing)
        bt !== nothing && return bt
    end

    # Priority 2: shop tag
    haskey(tags, "shop") && return COMMERCIAL_SHOP

    # Priority 3: office tag
    haskey(tags, "office") && return COMMERCIAL_OFFICE

    # Priority 4: tourism tag
    tourism = get(tags, "tourism", "")
    if tourism in TOURISM_COMMERCIAL
        return COMMERCIAL_SHOP
    end

    # Priority 5: building tag
    building = get(tags, "building", "")
    if !isempty(building)
        bt = get(BUILDING_TAG_TO_TYPE, building, nothing)
        bt !== nothing && return bt
    end

    return OTHER
end

# ── Capacity estimation ──────────────────────────────────────────────

# Area per person by building type (m2/person)
# Sources: Polish GUS 2021 census, typical building densities
const CAPACITY_DIVISOR = Dict{BuildingType,Float64}(
    RESIDENTIAL_HOUSE     => 30.0,    # 30 m2/person, 1 floor
    RESIDENTIAL_APARTMENT => 10.0,    # 30 m2/person, ~3 floors → 30/3 = 10
    COMMERCIAL_SHOP       => 20.0,    # 20 m2/worker (retail density)
    COMMERCIAL_OFFICE     => 15.0,    # 15 m2/worker (open-plan)
    INDUSTRIAL            => 50.0,    # 50 m2/worker (warehouse)
    EDUCATION             => 7.0,     # 10.5 m2/student gross (GUS), 1.5 floors → 10.5/1.5 = 7.0
    HEALTHCARE            => 25.0,    # 25 m2/staff
    PUBLIC                => 10.0,    # 10 m2/person
    RELIGIOUS             => 5.0,     # 5 m2/person (dense seating)
    OTHER                 => 30.0,    # fallback
)

"""
    estimate_capacity(btype::BuildingType, area_m2::Float64) → Int

Estimate person capacity of a building from its type and footprint area.

Returns 0 for tiny buildings (< 10 m2, typically garages or sheds).
Minimum capacity is 1 for non-tiny buildings.

Formulas by type:
- RESIDENTIAL_HOUSE: area / 30 (single floor, 30 m2/person)
- RESIDENTIAL_APARTMENT: area × 3 / 30 (3 floors assumed)
- EDUCATION: area × 2 / 5 (2 floors, 5 m2/student)
- Others: area / type-specific divisor

# Examples
```julia
estimate_capacity(RESIDENTIAL_HOUSE, 120.0)  # → 4
estimate_capacity(EDUCATION, 100.0)          # → 40
```
"""
function estimate_capacity(btype::BuildingType, area_m2::Float64)::Int
    area_m2 < 10.0 && return 0
    divisor = get(CAPACITY_DIVISOR, btype, 30.0)
    cap = area_m2 / divisor
    return max(1, round(Int, cap))
end

# ── POI classification ───────────────────────────────────────────────

# (poi_type, poi_value) → (building_type, capacity, default_label)
const POI_CLASSIFICATION = Dict{Tuple{String,String}, Tuple{BuildingType,Int,String}}(
    # Leisure
    ("leisure", "playground")      => (PUBLIC, 20, "Playground"),
    ("leisure", "pitch")           => (PUBLIC, 30, "Sports pitch"),
    ("leisure", "track")           => (PUBLIC, 20, "Running track"),
    ("leisure", "park")            => (PUBLIC, 50, "Park"),
    ("leisure", "garden")          => (PUBLIC, 20, "Garden"),
    ("leisure", "fitness_centre")  => (COMMERCIAL_SHOP, 15, ""),
    # Amenity
    ("amenity", "restaurant")      => (COMMERCIAL_SHOP, 30, ""),
    ("amenity", "cafe")            => (COMMERCIAL_SHOP, 20, ""),
    ("amenity", "bar")             => (COMMERCIAL_SHOP, 25, ""),
    ("amenity", "pub")             => (COMMERCIAL_SHOP, 25, ""),
    ("amenity", "fast_food")       => (COMMERCIAL_SHOP, 20, ""),
    ("amenity", "ice_cream")       => (COMMERCIAL_SHOP, 10, ""),
    ("amenity", "pharmacy")        => (HEALTHCARE, 10, ""),
    ("amenity", "doctors")         => (HEALTHCARE, 15, ""),
    ("amenity", "clinic")          => (HEALTHCARE, 20, ""),
    ("amenity", "townhall")        => (PUBLIC, 30, ""),
    ("amenity", "community_centre") => (PUBLIC, 40, ""),
    ("amenity", "fire_station")    => (PUBLIC, 15, ""),
    ("amenity", "police")          => (PUBLIC, 15, ""),
    ("amenity", "post_office")     => (PUBLIC, 10, ""),
    ("amenity", "fuel")            => (COMMERCIAL_SHOP, 10, ""),
    ("amenity", "school")          => (EDUCATION, 50, ""),
    ("amenity", "kindergarten")    => (EDUCATION, 20, ""),
    ("amenity", "university")      => (EDUCATION, 200, ""),
    # Shop
    ("shop", "supermarket")        => (COMMERCIAL_SHOP, 40, ""),
    ("shop", "convenience")        => (COMMERCIAL_SHOP, 15, ""),
    ("shop", "clothes")            => (COMMERCIAL_SHOP, 15, ""),
    ("shop", "chemist")            => (COMMERCIAL_SHOP, 15, ""),
    # Tourism
    ("tourism", "hotel")           => (COMMERCIAL_SHOP, 20, ""),
)

# Tags to check for POI classification, in priority order
const POI_TAG_KEYS = ["leisure", "amenity", "shop", "tourism"]

"""
    classify_poi(tags::Dict{String,String}) → Union{NamedTuple, Nothing}

Classify OSM tags as a point of interest.

Returns a NamedTuple `(poi_type, poi_value, building_type, capacity, label)`
if the tags match a known POI category, or `nothing` if not a POI.

Checks tags in priority order: leisure > amenity > shop > tourism.

# Examples
```julia
result = classify_poi(Dict("amenity" => "restaurant", "name" => "Foo"))
result.building_type  # COMMERCIAL_SHOP
result.capacity       # 30
```
"""
function classify_poi(tags::Dict{String,String})
    for key in POI_TAG_KEYS
        value = get(tags, key, "")
        isempty(value) && continue

        # Try exact match first
        classification = get(POI_CLASSIFICATION, (key, value), nothing)
        if classification !== nothing
            btype, cap, default_label = classification
            return (poi_type=key, poi_value=value, building_type=btype,
                    capacity=cap, label=default_label)
        end

        # Generic fallback for shop/office tags with any value
        if key == "shop"
            return (poi_type="shop", poi_value=value,
                    building_type=COMMERCIAL_SHOP, capacity=15, label="")
        end
    end

    # Check office separately (not in POI_TAG_KEYS priority list)
    office = get(tags, "office", "")
    if !isempty(office)
        return (poi_type="office", poi_value=office,
                building_type=COMMERCIAL_OFFICE, capacity=20, label="")
    end

    return nothing
end
