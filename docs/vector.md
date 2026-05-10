# Vector Search

NodeDB's vector engine supports HNSW indexing with SQ8/PQ quantization and cosine,
dot-product, and Euclidean distance metrics.

## Setup

```ruby
# Migration
create_collection :articles
create_vector_index :idx_articles_emb,
  on: :articles, column: :embedding, metric: :cosine, dim: 384

# Model
class Article < ApplicationRecord
  include NodeDB::Vector
  vector_column :embedding, dim: 384
end
```

## Nearest-neighbour search

```ruby
# Basic search — returns ActiveRecord::Result
results = Article.search_vector(:embedding, query_embedding, limit: 10)
results.each { |r| puts r["title"] }

# With a filter (safe SQL fragment, no user input)
Article.search_vector(:embedding, query_embedding, limit: 5, filter: "published = true")
```

## SQL emitted

```sql
SEARCH articles USING VECTOR(embedding, ARRAY[0.1, 0.2, ...], 10)
SEARCH articles USING VECTOR(embedding, ARRAY[0.1, 0.2, ...], 5) WHERE published = true
```

## Index options

| Option | Values | Default |
|--------|--------|---------|
| `metric` | `:cosine`, `:dot`, `:euclidean` | `:cosine` |
| `dim` | integer | required |
