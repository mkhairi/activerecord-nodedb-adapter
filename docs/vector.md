# Vector Search

NodeDB's vector engine supports HNSW indexing with SQ8/PQ quantization
and cosine, dot-product, and Euclidean distance metrics.

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
Article.search_vector(:embedding, query_embedding, limit: 10)
# => [{ "surrogate" => 12, "distance" => 0.043 }, ...]

# With a filter (safe SQL fragment, no user input; keep columns unqualified)
Article.search_vector(:embedding, query_embedding, limit: 5, filter: "published = true")
```

`search_vector` returns an Array of `{ "id", "surrogate", "distance" }`
hashes. NodeDB's `SEARCH ... USING VECTOR()` returns the document id and
the internal surrogate id plus the distance — it does **not** project
other document fields, and `SEARCH` cannot be wrapped in a subquery.
Look up content with a follow-up query when needed.

The `SEARCH` parser rejects a quoted collection name (a quoted column
is accepted since upstream `b04047b13`), so the concern emits bare
table/column names.

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
