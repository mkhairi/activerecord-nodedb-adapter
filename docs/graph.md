# Graph Engine

NodeDB's graph engine is an overlay on document collections — nodes are
documents, edges are stored as an adjacency structure. 13 graph
algorithms built-in.

## Setup

```ruby
# Migration — standard document collection; no extra DDL needed for edges
create_collection :social_nodes

# Model
class SocialNode < ApplicationRecord
  include NodeDB::Graph
  self.table_name = "social_nodes"
end
```

## Operations

```ruby
# Insert nodes (standard AR)
SocialNode.create!(id: "alice", name: "Alice")
SocialNode.create!(id: "bob",   name: "Bob")

# Insert a directed edge
SocialNode.graph_insert_edge(from: "alice", to: "bob", type: "follows",
                             properties: { since: 2024 })

# Traverse from a node — returns an Array of reachable node ids
SocialNode.graph_traverse(from: "alice", depth: 2)
SocialNode.graph_traverse(from: "alice", depth: 1, direction: :outbound)

# Run an algorithm
SocialNode.graph_algo(:pagerank, damping: 0.85, iterations: 20, tolerance: 1e-7)
SocialNode.graph_algo(:pagerank, personalization: { "alice" => 1.0, "bob" => 0.5 })
SocialNode.graph_algo(:betweenness)
SocialNode.graph_algo(:bfs, start: "alice")

# Delete an edge
SocialNode.graph_delete_edge(from: "alice", to: "bob", type: "follows")
```

## Edge-store counters

Persistent O(1) counters per collection via `SHOW GRAPH STATS`:

```ruby
SocialNode.graph_stats
# => [{ "collection" => "social_nodes", "node_count" => "4",
#       "edge_count" => "2", "distinct_label_count" => "1",
#       "labels" => "[{\"count\":2,\"label\":\"follows\"}]" }]

SocialNode.graph_stats(verbose: true)          # one row per (collection, label)
SocialNode.graph_stats(as_of: 1.hour.ago.to_i * 1000)

ActiveRecord::Base.connection.graph_stats      # tenant-wide, all collections
```

## SQL emitted

```sql
GRAPH INSERT EDGE IN social_nodes FROM 'alice' TO 'bob' TYPE 'follows' PROPERTIES '{"since":2024}'
GRAPH TRAVERSE FROM 'alice' DEPTH 2
GRAPH ALGO PAGERANK ON social_nodes DAMPING 0.85 PERSONALIZATION {"alice":1.0,"bob":0.5}
GRAPH DELETE EDGE FROM 'alice' TO 'bob' TYPE 'follows'
SHOW GRAPH STATS 'social_nodes'
```

The concern passes **bare** collection names in the `IN` / `ON`
clauses: NodeDB keys the edge store by the clause spelling verbatim,
so a double-quoted identifier would create a key that scoped
`SHOW GRAPH STATS` lookups miss.

## Supported algorithms

`pagerank` (with optional `personalization:`), `betweenness`,
`closeness`, `bfs`, `dfs`, `scc`, `wcc`, `triangle_count`,
`clustering_coefficient`, `shortest_path`, `all_pairs_shortest_path`,
`community_detection`, `label_propagation`

## Known limitations (current upstream)

- **No MATCH helper yet** — upstream's Cypher-style
  `MATCH ... IN <collection>` executor ignores the collection scope
  and returns edges from every collection in the tenant (BUG-023), so
  the concern doesn't expose it.
- Plain `DROP COLLECTION` leaves the collection's edge-store entries
  visible to `SHOW GRAPH STATS` (same upstream bug family).
