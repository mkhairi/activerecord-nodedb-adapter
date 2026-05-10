# Graph Engine

NodeDB's graph engine is an overlay on document collections — nodes are documents,
edges are stored as an adjacency structure. 13 graph algorithms built-in.

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

# Traverse from a node
SocialNode.graph_traverse(from: "alice", depth: 2)
SocialNode.graph_traverse(from: "alice", depth: 1, direction: :outbound)

# Run an algorithm
SocialNode.graph_algo(:pagerank, damping: 0.85, iterations: 20, tolerance: 1e-7)
SocialNode.graph_algo(:betweenness)
SocialNode.graph_algo(:bfs, start: "alice")

# Delete an edge
SocialNode.graph_delete_edge(from: "alice", to: "bob", type: "follows")
```

## SQL emitted

```sql
GRAPH INSERT EDGE FROM 'alice' TO 'bob' TYPE 'follows' PROPERTIES '{"since":2024}'
GRAPH TRAVERSE FROM 'alice' DEPTH 2
GRAPH ALGO PAGERANK ON social_nodes DAMPING 0.85 ITERATIONS 20 TOLERANCE 1e-07
```

## Supported algorithms

`pagerank`, `betweenness`, `closeness`, `bfs`, `dfs`, `scc`, `wcc`, `triangle_count`,
`clustering_coefficient`, `shortest_path`, `all_pairs_shortest_path`, `community_detection`,
`label_propagation`
