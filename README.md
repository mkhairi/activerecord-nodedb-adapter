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
| Sample app        | `../../sample_rails_app` (Rails 8.1, full CRUD demo) |

## Installation

Both this gem and `nodedb-ruby` are alpha and not yet on rubygems. Pull
from GitHub via Bundler's `github:` shorthand:

```ruby
gem "pg", "~> 1.5"
gem "nodedb-ruby",                 github: "mkhairi/nodedb-ruby",                 branch: "main"
gem "activerecord-nodedb-adapter", github: "mkhairi/activerecord-nodedb-adapter", branch: "main"
```

For SSH-only setups: `bundle config github.https false` (one-time).

Working sample: <https://github.com/mkhairi/nodedb-on-rails> — Rails 8.1
app exercising every NodeDB engine.

For monorepo development against local checkouts:

```ruby
gem "nodedb-ruby",                 path: "../nodedb-ruby"
gem "activerecord-nodedb-adapter", path: "../activerecord-nodedb-adapter"
```

Once the gems ship to rubygems, the standard form will work:

```ruby
gem "activerecord-nodedb-adapter"
gem "pg", "~> 1.5"
```

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

The standard `migration_error: :page_load` Rails default works — the
adapter ships NodeDB-aware `SchemaMigration` and `InternalMetadata`
classes (see *Schema migrations* below) so AR can track applied
migrations as a regular `schema_migrations` collection.

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

### Generic helper

```ruby
create_collection :articles                        # document (schemaless)
create_collection :metrics,  engine: :timeseries
create_collection :sessions, engine: :kv
create_collection :places,   engine: :spatial

create_vector_index :idx_emb, on: :articles,
  column: :embedding, metric: :cosine, dim: 384
drop_vector_index   :idx_emb
```

### Per-engine shorthands

```ruby
create_timeseries      :metrics
create_kv              :sessions
create_columnar        :events
create_spatial         :locations
create_document_strict :articles do |t|
  # block-form columns work for any engine
end
```

### Engine-specific WITH options

Pass `engine_options:` to thread arbitrary settings into the `WITH (...)`
clause:

```ruby
create_collection :metrics, engine: :timeseries,
  engine_options: { retention: "7d", compression: "zstd" }
# CREATE COLLECTION metrics (...)
# WITH (engine='timeseries', retention='7d', compression='zstd')
```

### Strict-schema collections

For typed CRUD-style models, prefer the strict-schema engine (otherwise
unknown columns are silently dropped):

```ruby
execute <<~SQL
  CREATE COLLECTION articles (
    id    TEXT PRIMARY KEY,
    title TEXT,
    body  TEXT
  ) WITH (engine='document_strict')
SQL
```

A custom block-form `t.text` / `t.vector` / `t.geometry` DSL is on the
roadmap; for now use raw `execute` for typed columns.

## Type casters

Engine-specific Ruby <-> NodeDB-literal casting is registered automatically
on connection bootstrap. Declare attributes on your model and AR rounds
them through the right Ruby type:

```ruby
class Article < ApplicationRecord
  attribute :embedding, :vector       # Array<Float>     <-> "[0.1, 0.2, ...]"
  attribute :payload,   :json         # Hash / Array     <-> JSON string
  attribute :geom,      :geometry     # WKT string passthrough (BUG-011 follow-up)
end

Article.new(embedding: [0.1, 0.2, 0.3], payload: { source: "demo" })
```

Plus the connection-level quoting hook accepts Ruby values directly in raw
SQL:

```ruby
ActiveRecord::Base.connection.quote([0.1, 0.2, 0.3])
# => "'[0.1, 0.2, 0.3]'"

ActiveRecord::Base.connection.quote({ "k" => 1 })
# => "'{\"k\":1}'"
```

## Schema migrations

The adapter ships NodeDB-aware replacements for
`ActiveRecord::SchemaMigration` and `ActiveRecord::InternalMetadata`.
They auto-register on connection — Rails' standard migration tooling
works out of the box:

```ruby
# Create the tracking collections (idempotent)
connection_pool = ActiveRecord::Base.connection_pool
connection_pool.schema_migration.create_table   # CREATE COLLECTION schema_migrations ...
connection_pool.internal_metadata.create_table  # CREATE COLLECTION ar_internal_metadata ...

# Record an already-applied migration
connection_pool.schema_migration.create_version("20260101000000")

# Inspect
connection_pool.schema_migration.versions
# => ["20260101000000"]
```

`rails db:migrate`, `rails db:rollback`, and the dev-mode
`migration_error: :page_load` check all work against these collections.

Implementation notes:

- `CREATE COLLECTION schema_migrations (id TEXT PRIMARY KEY) WITH (engine='document_strict')`
- Lookup keys (versions, metadata keys) live in NodeDB's mandatory `id`
  column; declaring a non-`id` PK triggers a duplicate-empty-id collision
  on the second INSERT (NodeDB upstream quirk).
- DELETE path uses the BUG-008 workaround so `db:rollback` actually
  persists the version removal.

## Per-call session settings

`with_settings { … }` sets NodeDB session variables for the duration of the
block, restoring them on exit. Useful for one-off tweaks (FTS fuzzy
distance, vector probe depth, query memory budgets) without polluting the
global connection state:

```ruby
ActiveRecord::Base.connection.with_settings(application_name: "import-job") do
  Article.insert_all(big_batch)
end
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
      `drop_collection(if_exists:)`, `drop_vector_index`
- [x] Per-engine helpers: `create_timeseries`, `create_kv`, `create_columnar`,
      `create_spatial`, `create_document_strict`
- [x] `engine_options:` kwarg threads arbitrary settings into the WITH clause
- [x] Custom `SchemaCreation` for engine-aware DDL serialization
- [x] NodeDB-aware `SchemaMigration` + `InternalMetadata` so `rails db:migrate`,
      `db:rollback`, `db:migrate:status`, `db:seed`, and the dev-mode
      `migration_error: :page_load` check all work against `schema_migrations` /
      `ar_internal_metadata` collections
- [x] Advisory-lock stubs (`get_advisory_lock` / `release_advisory_lock`) so
      AR's concurrent-migration guard doesn't trip — pair returns `true`
- [x] `Nodedb::SchemaDumper` emits engine-aware DDL into `db/schema.rb`
- [x] Type casters: `attribute :col, :vector` / `:json` / `:geometry`
- [x] Quoting hooks: `Array<Numeric>` → VECTOR literal, `Hash` → JSON literal
- [x] `connection.with_settings { … }` block for scoped session vars
- [x] Model concerns: `NodeDB::Vector`, `Graph`, `Timeseries`, `Spatial`, `KV`,
      `FullTextSearch`
- [x] `record.destroy` workaround for NodeDB BUG-008 (DELETE-in-txn dropped)
- [x] `Graph.silence_libpq_noise` filter for harmless libpq stderr warnings
- [x] FTS row normalisation (filters non-matches, unwraps fuzzy-mode JSON)
- [x] `drop_collection` rescues missing-collection errors when `if_exists: true`
- [x] Sample Rails 8 app with full CRUD walkthrough (`../../sample_rails_app`)

### Pending
- [ ] Auto-unwrap of schemaless `SELECT *` rows (currently returns
      `{ "result" => "<json>" }`)
- [ ] SQL rewriter to strip the `"table".col` qualifier so AR's default
      projection (`SELECT "articles".*`) returns flat columns
- [ ] Silence harmless `INSERT EDGE` `pg`-gem stderr warnings
- [ ] Generators (`rails g nodedb:collection`, `nodedb:vector_index`)
- [ ] Connection pool aware fixtures helper for RSpec
- [ ] CHANGELOG.md
- [ ] gemspec push to RubyGems (currently consumed via `path:`)

## Known issues

NodeDB-side parser quirks and limits, grouped by status. Each is tracked
in `docs/bugs/`.

### Resolved upstream

- **BUG-001** `ResourcesExhausted` on non-timeseries INSERT — fixed in
  `nodedb/src/config/engine.rs` + `memory/startup.rs`.
- **BUG-005** Prepared statements missing `RowDescription` — fixed
  upstream; adapter still uses simple-query mode for safety.
- **BUG-006** Boolean column OID 0 — fixed upstream; no `unknown OID`
  warnings emitted.

### Adapter compensates transparently

You write idiomatic AR; the adapter swallows the workaround:

- **`schema_migrations` / `ar_internal_metadata` tables (#24)** — NodeDB-aware
  subclasses use `CREATE COLLECTION` + raw unqualified SQL. `rails
  db:migrate` and `migration_error: :page_load` work normally.
- **BUG-008** DELETE inside transaction silently dropped — `exec_delete`
  override commits + re-issues the DELETE outside the AR-opened
  transaction so `record.destroy` actually persists.
- **BUG-010** `text_match()` predicate doesn't filter rows — `fts_search`
  drops rows whose `bm25_score` is null.
- **BUG-013** FTS fuzzy mode returns single `result` column wrapping JSON
  — `fts_search` JSON-parses and unwraps.
- **GRAPH TRAVERSE** returns a single row with a JSON array — `Graph`
  concern parses automatically.
- **GRAPH INSERT EDGE** now requires `IN 'collection'` — `Graph` concern
  threads `in_collection:` automatically.
- **BUG-007** `pg_attribute` query returns duplicate `id` row — adapter
  uses `DESCRIBE` fallback in `column_definitions`.
- **libpq stderr noise** on `INSERT EDGE`, `GRAPH …` command tags —
  `Graph.silence_libpq_noise` block filter.
- **`SEARCH … USING VECTOR()` rejects quoted identifiers** — `Vector`
  concern emits bare column names.

### Requires user awareness

These leak through to model code; the workaround is a one-line model
declaration:

- **NodeDB rejects qualified column refs** in projections. `articles.id`
  and `"articles"."id"` return nil for select lists. Use a model
  `default_scope { select("id, title, body") }` with unqualified column
  names. AR's `WHERE "articles"."id" = '…'` for `find` *does* work — only
  projections are affected.
- **`SELECT *` on schemaless document collections** returns
  `{"result" => "<json>"}` instead of flat columns. Either project
  explicit columns (per above) or use the `document_strict` engine.
- **`SEARCH` cannot be wrapped in subqueries.** `IN (SEARCH …)`,
  `FROM (SEARCH …)`, and `SELECT id FROM (SEARCH …)` all fail to parse.
  The Vector concern returns surrogate + distance and lets you do a
  follow-up `find`.
- **`document_strict` requires the user-facing PK to live in the
  built-in `id` column.** Declaring a custom `version TEXT PRIMARY KEY`
  triggers a duplicate-empty-id collision on the second INSERT. Sample
  workaround: store the lookup key in `id` directly.

### Open / limited workaround

- **BUG-002** `SELECT version()` returns empty — adapter uses
  `SHOW server_version` instead.
- **BUG-003** `PQserverVersion()` raises `PG::ConnectionBad` — adapter
  hardcodes `160000` for `database_version` / `get_database_version`.
- **BUG-004** `DROP COLLECTION IF EXISTS` parses `IF` as a collection
  name when target is present — `drop_collection(if_exists:)` rescues
  the not-found error instead.
- **BUG-009** `INSERT` command tag missing OID slot — produces stderr
  noise on every successful INSERT. Tracked; covered case-by-case via
  `silence_libpq_noise`.
- **BUG-011** Spatial INSERT does not evaluate `ST_GeomFromText` —
  values stored as literal SQL text. Sample app uses `document_strict`
  engine with explicit `lat FLOAT, lon FLOAT` columns and computes
  haversine in Ruby.
- **BUG-012** Spatial engine drops non-geometry typed columns silently
  on INSERT. Combined with BUG-011, no working storage path exists in
  the spatial engine today.
- **DROP+CREATE preserves rows within retention window.** NodeDB
  soft-deletes the storage; a fresh `CREATE COLLECTION` of the same name
  resurrects the old rows. Use `UNDROP COLLECTION name` then
  `DELETE FROM name` to clear, or wait for the retention window to
  expire. `bin/setup` in the sample app reconciles this for
  `schema_migrations` automatically.

## License

Released under the **BSD 2-Clause License**. Full text: [LICENSE.md](LICENSE.md).

Independent third-party adapter. Not affiliated with, endorsed by, or
maintained by the NodeDB project. "NodeDB" is referenced solely to identify
the database this gem connects to.
