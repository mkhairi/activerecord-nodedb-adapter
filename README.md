# activerecord-nodedb-adapter

> ## ⚠️ ALPHA — DO NOT USE IN PRODUCTION
>
> Version: **`0.1.0.alpha.1`**.
>
> This adapter is **experimental and unaudited**. It has **never been used or
> tested in any production environment**. The migration DSL, model concerns,
> and underlying SQL emission may change without notice between alpha
> releases. NodeDB itself is also early-stage, with several parser quirks the
> adapter currently works around (see *Known issues* below).
>
> Run it on disposable data only. Do not point it at customer data, billing
> systems, anything regulated, or any system you cannot trivially rebuild from
> scratch.

ActiveRecord adapter for [NodeDB](https://nodedb.dev) — a distributed
multi-model database that exposes vector, graph, document, columnar,
timeseries, spatial, KV, and FTS engines through a single PostgreSQL-wire
binary on port 6432.

The adapter extends `ActiveRecord::ConnectionAdapters::PostgreSQLAdapter` and
adds idiomatic Rails APIs (model concerns, migration DSL) for each NodeDB
engine. Sits on top of [`nodedb-ruby`](../nodedb-ruby) for connection
handling and SQL building.

## Status

| Area              | State |
| ----------------- | ----- |
| AR base adapter   | Working — extends PostgreSQLAdapter, simple-query mode |
| Migration DSL     | Working — `create_collection`, `create_vector_index`, `drop_collection` |
| Model concerns    | Vector, Graph, Timeseries, Spatial, KV, FTS |
| Test suite        | 13 examples / 0 failures / 0 pending |
| Rails versions    | 7.1+, 8.x verified |
| Ruby versions     | 3.2+ (developed on 4.0.1) |
| Sample app        | `../sample_rails_app` (Rails 8.1, full CRUD demo) |

## Installation

```ruby
gem "activerecord-nodedb-adapter"
gem "pg", "~> 1.5"
```

`activerecord-nodedb-adapter` depends on `nodedb-ruby`; both ship together.

## Configuration

```yaml
# config/database.yml
default: &default
  adapter:  nodedb
  host:     localhost
  port:     6432
  database: myapp
  username: nodedb
  password: <%= ENV["NODEDB_PASSWORD"] %>
```

In Rails 8 development, also disable the migration check (NodeDB has no
`schema_migrations` table):

```ruby
# config/environments/development.rb
config.active_record.migration_error = false
```

## Engines

### Vector search

```ruby
class Article < ApplicationRecord
  include NodeDB::Vector
  vector_column :embedding, dim: 384
end

Article.search_vector(:embedding, query_embedding, limit: 10)
# => [{ "surrogate" => 12, "distance" => 0.043 }, ...]
```

The result rows expose NodeDB's internal surrogate IDs and cosine distance.
The `SEARCH ... USING VECTOR()` operator does not project document fields,
so look up content with a follow-up `find` if needed.

### Graph

```ruby
class SocialNode < ApplicationRecord
  include NodeDB::Graph
end

SocialNode.graph_insert_edge(from: "alice", to: "bob", type: "follows")
SocialNode.graph_traverse(from: "alice", depth: 3)
# => ["bob", "carol", ...]
SocialNode.graph_algo(:pagerank, damping: 0.85, iterations: 20)
```

### Timeseries

```ruby
class Metric < ApplicationRecord
  include NodeDB::Timeseries
end

Metric.since(1.hour.ago).where(host: "web-01")
Metric.select(Metric.time_bucket("5 minutes")).group("bucket")
```

### Spatial

```ruby
class Location < ApplicationRecord
  include NodeDB::Spatial
end

Location.within_distance(lat: 40.75, lon: -73.98, meters: 500)
Location.order_by_distance(lat: 40.75, lon: -73.98).limit(5)
```

### Key-Value

```ruby
class KvSession < ApplicationRecord
  include NodeDB::KV
  self.primary_key = :key
end

KvSession.kv_set("sess_abc", "token-xyz", ttl: 3600)
KvSession.kv_get("sess_abc")  # => "token-xyz"
```

### Full-text search

```ruby
class Post < ApplicationRecord
  include NodeDB::FullTextSearch
  fts_column :body, language: "english"
end

Post.fts_search("machine learning", limit: 20)
Post.fts_search("nural networks", fuzzy: true)
```

## Migrations

```ruby
create_collection :articles                        # document (schemaless)
create_collection :metrics,  engine: :timeseries
create_collection :sessions, engine: :kv
create_collection :places,   engine: :spatial

create_vector_index :idx_emb, on: :articles,
  column: :embedding, metric: :cosine, dim: 384
```

For typed CRUD-style models, prefer the strict-schema engine (otherwise unknown
columns are silently dropped):

```ruby
execute <<~SQL
  CREATE COLLECTION articles (
    id    TEXT PRIMARY KEY,
    title TEXT,
    body  TEXT
  ) WITH (engine='document_strict')
SQL
```

## Requirements

- Ruby 3.2+
- Rails 7.1+ (verified on 8.1.3)
- NodeDB v0.1+ (pgwire on port 6432)

## Feature checklist

### Implemented
- [x] Connection adapter that registers under `adapter: nodedb`
- [x] Simple-query mode (NodeDB does not implement extended-query
      `RowDescription` for prepared statements)
- [x] `database_version` stub returning `160000` so AR's PG version guards pass
- [x] `nodedb_version` introspection from `SHOW server_version`
- [x] Migration DSL: `create_collection`, `create_vector_index`,
      `drop_collection(if_exists:)`
- [x] Custom `SchemaCreation` for engine-aware DDL serialization
- [x] Column type registration (vector, geometry, json, uuid)
- [x] Model concerns: `NodeDB::Vector`, `Graph`, `Timeseries`, `Spatial`, `KV`,
      `FullTextSearch`
- [x] `drop_collection` rescues missing-collection errors when `if_exists: true`
- [x] Sample Rails 8 app with full CRUD walkthrough (`../sample_rails_app`)

### Pending
- [ ] Auto-unwrap of schemaless `SELECT *` rows (currently returns
      `{ "result" => "<json>" }`)
- [ ] SQL rewriter to strip the `"table".col` qualifier so AR's default
      projection (`SELECT "articles".*`) returns flat columns
- [ ] Stub `schema_migrations` reads so `migration_error: :page_load` works
- [ ] Silence harmless `INSERT EDGE` `pg`-gem stderr warnings
- [ ] Generators (`rails g nodedb:collection`, `nodedb:vector_index`)
- [ ] `db:seed` / `db:migrate:status` integration
- [ ] Connection pool aware fixtures helper for RSpec
- [ ] CHANGELOG.md
- [ ] gemspec push to RubyGems (currently consumed via `path:`)

## Known issues

NodeDB-side parser quirks the adapter has to dance around. Each is tracked in
`../bugs/`.

- **`SELECT *` on document collections returns wrapped JSON.** Workaround:
  `default_scope { select("id, …") }` with unqualified column names. Adapter
  fix tracked above.
- **NodeDB rejects qualified column refs.** `articles.id` and
  `"articles"."id"` resolve to nil. Use unqualified names in projections.
  AR's `WHERE "articles"."id" = '…'` does work for `find` because it goes
  through a code path NodeDB does parse; only projections break.
- **`SEARCH … USING VECTOR()` rejects quoted identifiers.** The
  `NodeDB::Vector#search_vector` concern always emits bare names.
- **`SEARCH` cannot be wrapped in subqueries.** `IN (SEARCH …)`,
  `FROM (SEARCH …)`, and `WHERE id IN (SELECT id FROM (SEARCH …))` all fail
  to parse. The vector concern returns surrogate + distance and lets you
  follow up with a `find`.
- **GRAPH TRAVERSE returns a single row whose `result` column is a JSON
  array of node IDs.** The Graph concern parses that automatically.
- **GRAPH INSERT EDGE now requires `IN 'collection'`.** Builder updated; if
  you call the SQL builder directly you must pass `in_collection:`.
- **No `schema_migrations` table.** Disable `migration_error` in dev or stub
  it (pending adapter task).
- **BUG-001 (`ResourcesExhausted` on non-timeseries INSERT).** Fixed
  upstream in `nodedb/src/config/engine.rs` + `memory/startup.rs`. See
  `../bugs/001-*.md`.

## License

BSD 2-Clause — same style as [ruby-pg](https://github.com/ged/ruby-pg/blob/master/LICENSE).
See [LICENSE.md](LICENSE.md).

This gem is an independent third-party adapter. It is not affiliated with,
endorsed by, or maintained by the NodeDB project.
