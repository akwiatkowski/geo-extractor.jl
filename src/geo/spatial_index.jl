# Spatial index for fast geographic nearest-neighbor and radius queries.
#
# Wraps NearestNeighbors.jl KD-tree with geographic coordinate support.
# Internally projects coordinates to local meters (equirectangular)
# so Euclidean KD-tree queries approximate real distances.
#
# Accurate for point sets spanning <100 km (typical settlement scale).

using NearestNeighbors: KDTree, knn, inrange

"""
    SpatialIndex{T}

Spatial index for fast nearest-neighbor and radius queries on geographic data.

Internally converts all coordinates to local meters via equirectangular
projection (centered on the data centroid) and builds a KD-tree.
Query results approximate true Haversine distances — accurate when
the indexed points span less than ~100 km.

# Type parameter
- `T` — type of indexed items (any type; position extracted via `coord_fn`)

# Examples
```julia
buildings = [(id=1, pos=Coord(52.40, 16.92)), (id=2, pos=Coord(52.41, 16.93))]
idx = SpatialIndex(buildings, b -> b.pos)
find_nearest(idx, Coord(52.40, 16.92), 1)   # → [(id=1, ...)]
find_within_radius(idx, Coord(52.40, 16.92), 500.0)  # items within 500 m
```
"""
struct SpatialIndex{T}
    tree::Any   # KDTree or nothing — internal implementation detail
    items::Vector{T}
    coords::Vector{Coord}
    ref::Coord  # projection reference point (centroid of all items)
end

"""
    SpatialIndex(items, coord_fn) → SpatialIndex{T}

Build a spatial index from a collection of items.

# Arguments
- `items` — collection of items to index
- `coord_fn` — function `item → Coord` extracting the geographic position

The index is immutable after construction. Rebuilding is cheap for
typical settlement sizes (thousands of items, <1 ms).

# Examples
```julia
# Index any type — just provide a coord extraction function
stops = [BusStop(1, Coord(52.40, 16.92)), BusStop(2, Coord(52.41, 16.93))]
idx = SpatialIndex(stops, s -> s.position)
```
"""
function SpatialIndex(items::AbstractVector{T}, coord_fn::Function) where T
    items_vec = collect(items)
    n = length(items_vec)

    if n == 0
        return SpatialIndex{T}(nothing, items_vec, Coord[], Coord(0.0, 0.0))
    end

    coords = [coord_fn(item)::Coord for item in items_vec]

    # Reference point = centroid (minimizes projection error across the set)
    ref = Coord(
        sum(c.lat for c in coords) / n,
        sum(c.lon for c in coords) / n,
    )

    # Project all coords to local meters for Euclidean KD-tree
    points = Matrix{Float64}(undef, 2, n)
    for i in 1:n
        m = to_meters(coords[i], ref)
        points[1, i] = m.x
        points[2, i] = m.y
    end

    tree = KDTree(points)
    return SpatialIndex{T}(tree, items_vec, coords, ref)
end

"""
    find_nearest(idx::SpatialIndex, coord::Coord, k::Int=1) → Vector{T}

Find the `k` nearest items to `coord`. Results sorted by distance (closest first).

Returns empty vector if index is empty or `k ≤ 0`.

# Examples
```julia
nearest = find_nearest(idx, Coord(52.40, 16.92))       # closest 1
nearest5 = find_nearest(idx, Coord(52.40, 16.92), 5)   # closest 5
```
"""
function find_nearest(idx::SpatialIndex{T}, coord::Coord, k::Int=1)::Vector{T} where T
    (idx.tree === nothing || k <= 0) && return T[]
    k = min(k, length(idx.items))

    m = to_meters(coord, idx.ref)
    point = [m.x, m.y]
    idxs, _ = knn(idx.tree, point, k, true)  # true = sort by distance
    return [idx.items[i] for i in idxs]
end

"""
    find_nearest_idx_dist(idx::SpatialIndex, coord::Coord) → (index::Int, dist_m::Float64)

Find the nearest item and return its 1-based index into `idx.items` along with
the approximate distance in meters (equirectangular projection).

Returns `(0, Inf)` if the index is empty.

# Examples
```julia
i, d = find_nearest_idx_dist(idx, Coord(52.40, 16.92))
item = idx.items[i]   # same as find_nearest(idx, coord)[1]
```
"""
function find_nearest_idx_dist(idx::SpatialIndex, coord::Coord)::Tuple{Int, Float64}
    idx.tree === nothing && return (0, Inf)

    m = to_meters(coord, idx.ref)
    point = [m.x, m.y]
    idxs, dists = knn(idx.tree, point, 1, true)
    return (idxs[1], dists[1])
end

"""
    find_within_radius(idx::SpatialIndex, coord::Coord, radius_m::Real) → Vector{T}

Find all items within `radius_m` meters of `coord`.

Results are **not** sorted by distance. Uses equirectangular approximation —
accurate for radii under ~50 km.

Returns empty vector if index is empty or `radius_m ≤ 0`.

# Examples
```julia
nearby = find_within_radius(idx, Coord(52.40, 16.92), 500.0)  # within 500 m
```
"""
function find_within_radius(idx::SpatialIndex{T}, coord::Coord, radius_m::Real)::Vector{T} where T
    (idx.tree === nothing || radius_m <= 0) && return T[]

    m = to_meters(coord, idx.ref)
    point = [m.x, m.y]
    idxs = inrange(idx.tree, point, Float64(radius_m))
    return [idx.items[i] for i in idxs]
end

# ── Base extensions ──────────────────────────────────────────────────

"""Number of items in the spatial index."""
Base.length(idx::SpatialIndex)::Int = length(idx.items)

"""Check if the spatial index is empty."""
Base.isempty(idx::SpatialIndex)::Bool = isempty(idx.items)
