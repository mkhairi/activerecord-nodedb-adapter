# activerecord-nodedb-adapter

ActiveRecord adapter for [NodeDB](https://nodedb.dev) — a distributed multi-model database
exposing 8 engines via PostgreSQL wire protocol.

## Quick Setup

### 1. Add to Gemfile

```ruby
gem "activerecord-nodedb-adapter"
gem "pg", "~> 1.5"
```

### 2. Configure database.yml

```yaml
default: &default
  adapter: nodedb
  host: localhost
  port: 6432       # NodeDB pgwire port (default)
  database: myapp

development:
  <<: *default

test:
  <<: *default
  database: myapp_test
```

### 3. Start NodeDB

```bash
docker run -d \
  -p 6432:6432 -p 6433:6433 -p 6480:6480 \
  -v nodedb-data:/var/lib/nodedb \
  farhansyah/nodedb:latest
```

## Engines

| Engine | Module | Guide |
|--------|--------|-------|
| Vector search | `NodeDB::Vector` | [vector.md](vector.md) |
| Graph | `NodeDB::Graph` | [graph.md](graph.md) |
| Timeseries | `NodeDB::Timeseries` | [timeseries.md](timeseries.md) |
| Spatial | `NodeDB::Spatial` | [spatial.md](spatial.md) |
| Key-Value | `NodeDB::KV` | [kv.md](kv.md) |
| Full-Text Search | `NodeDB::FullTextSearch` | [full_text_search.md](full_text_search.md) |

## Migrations

NodeDB uses `CREATE COLLECTION` instead of `CREATE TABLE` for schemaless/document
collections. The adapter provides helper methods:

```ruby
class CreateArticles < ActiveRecord::Migration[7.1]
  def up
    create_collection :articles
    create_vector_index :idx_articles_embedding,
      on: :articles, column: :embedding, metric: :cosine, dim: 384
  end

  def down
    drop_collection :articles
  end
end
```

For typed (strict) or engine-specific collections:

```ruby
create_collection :metrics,  engine: :timeseries
create_collection :sessions, engine: :kv
create_collection :places,   engine: :spatial
```

Standard `create_table` still works for strict-schema collections using NodeDB's
PostgreSQL-compatible DDL.

## Requirements

- Ruby 3.2+
- Rails 7.1+
- NodeDB v0.1+ running with pgwire enabled (port 6432)
