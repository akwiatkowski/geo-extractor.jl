# Low-level OSM XML parser using LightXML.
#
# Parses .osm files (XML format) into raw node/way/relation collections.
# Higher-level extraction modules (buildings, roads, pois) consume OsmData.
#
# Uses DOM parsing — fine for town-sized files (5-50 MB) produced by osmium extract.
# Not suitable for parsing the full Poland PBF directly.

using LightXML

# ── Internal types ───────────────────────────────────────────────────

"""Raw OSM node: a point with coordinates and optional tags."""
struct OsmNode
    id::Int64
    coord::Coord
    tags::Dict{String,String}
end

"""Raw OSM way: an ordered list of node references with tags."""
struct OsmWay
    id::Int64
    node_refs::Vector{Int64}
    tags::Dict{String,String}
end

"""Member of an OSM relation."""
struct OsmRelationMember
    type::Symbol     # :node, :way, :relation
    ref::Int64
    role::String
end

"""Raw OSM relation: a group of members with tags."""
struct OsmRelation
    id::Int64
    members::Vector{OsmRelationMember}
    tags::Dict{String,String}
end

"""
    OsmData

Raw parsed OSM data containing nodes, ways, and relations.
Produced by [`parse_osm_xml`](@ref).

# Fields
- `nodes::Dict{Int64, OsmNode}` — all nodes keyed by ID
- `ways::Dict{Int64, OsmWay}` — all ways keyed by ID
- `relations::Dict{Int64, OsmRelation}` — all relations keyed by ID
"""
struct OsmData
    nodes::Dict{Int64, OsmNode}
    ways::Dict{Int64, OsmWay}
    relations::Dict{Int64, OsmRelation}
end

# ── Parser ───────────────────────────────────────────────────────────

"""
    parse_osm_xml(path::String) → OsmData

Parse an OSM XML file into raw nodes, ways, and relations.

Uses LightXML DOM parsing. Suitable for town-sized files (up to ~50 MB)
as typically produced by osmium extract.

# Examples
```julia
data = parse_osm_xml("town.osm")
length(data.nodes)  # number of nodes
```
"""
function parse_osm_xml(path::String)::OsmData
    isfile(path) || error("OSM file not found: $path")

    doc = parse_file(path)
    root_elem = root(doc)

    nodes = Dict{Int64, OsmNode}()
    ways = Dict{Int64, OsmWay}()
    relations = Dict{Int64, OsmRelation}()

    for child in child_elements(root_elem)
        ename = name(child)
        if ename == "node"
            node = _parse_node(child)
            nodes[node.id] = node
        elseif ename == "way"
            way = _parse_way(child)
            ways[way.id] = way
        elseif ename == "relation"
            rel = _parse_relation(child)
            relations[rel.id] = rel
        end
    end

    free(doc)
    return OsmData(nodes, ways, relations)
end

function _parse_node(elem)::OsmNode
    id = parse(Int64, attribute(elem, "id"))
    lat = parse(Float64, attribute(elem, "lat"))
    lon = parse(Float64, attribute(elem, "lon"))
    tags = _parse_tags(elem)
    return OsmNode(id, Coord(lat, lon), tags)
end

function _parse_way(elem)::OsmWay
    id = parse(Int64, attribute(elem, "id"))
    node_refs = Int64[]
    tags = Dict{String,String}()

    for child in child_elements(elem)
        cname = name(child)
        if cname == "nd"
            push!(node_refs, parse(Int64, attribute(child, "ref")))
        elseif cname == "tag"
            tags[attribute(child, "k")] = attribute(child, "v")
        end
    end

    return OsmWay(id, node_refs, tags)
end

function _parse_relation(elem)::OsmRelation
    id = parse(Int64, attribute(elem, "id"))
    members = OsmRelationMember[]
    tags = Dict{String,String}()

    for child in child_elements(elem)
        cname = name(child)
        if cname == "member"
            mtype = Symbol(attribute(child, "type"))
            ref = parse(Int64, attribute(child, "ref"))
            role = attribute(child, "role")
            push!(members, OsmRelationMember(mtype, ref, role))
        elseif cname == "tag"
            tags[attribute(child, "k")] = attribute(child, "v")
        end
    end

    return OsmRelation(id, members, tags)
end

function _parse_tags(elem)::Dict{String,String}
    tags = Dict{String,String}()
    for child in child_elements(elem)
        if name(child) == "tag"
            tags[attribute(child, "k")] = attribute(child, "v")
        end
    end
    return tags
end

# ── Coordinate resolution ────────────────────────────────────────────

"""
    resolve_way_coords(way::OsmWay, nodes::Dict{Int64, OsmNode}) → Vector{Coord}

Resolve a way's node references to geographic coordinates.
Skips references to nodes not present in the nodes dict.

# Examples
```julia
data = parse_osm_xml("town.osm")
way = data.ways[100]
coords = resolve_way_coords(way, data.nodes)
```
"""
function resolve_way_coords(way::OsmWay, nodes::Dict{Int64, OsmNode})::Vector{Coord}
    coords = Coord[]
    sizehint!(coords, length(way.node_refs))
    for ref in way.node_refs
        node = get(nodes, ref, nothing)
        node !== nothing && push!(coords, node.coord)
    end
    return coords
end
