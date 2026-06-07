# activerecord-nodedb-adapter

> ## ⚠️ ALPHA — DO NOT USE IN PRODUCTION
>
> Version: **`0.1.0.alpha.8`**. Tracks NodeDB **v0.3.0** (commit `25040fdf`, 2026-06-07). Requires `nodedb-ruby >= 0.1.0.alpha.5`.
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

## Companion packages

| Repo | Role |
| ---- | ---- |
| [`mkhairi/nodedb-ruby`](https://github.com/mkhairi/nodedb-ruby) | core — pgwire connection, type map, SQL builders |
| [`mkhairi/activerecord-nodedb-adapter`](https://github.com/mkhairi/activerecord-nodedb-adapter) | **this gem** — Rails ActiveRecord adapter |
| [`mkhairi/sequel-nodedb-adapter`](https://github.com/mkhairi/sequel-nodedb-adapter) | Sequel adapter (stub) |
| [`mkhairi/nodedb-on-rails`](https://github.com/mkhairi/nodedb-on-rails) | Rails 8 sample app exercising every NodeDB engine |

## Status

| Area              | State |
| ----------------- | ----- |
| AR base adapter   | Working — extends PostgreSQLAdapter, simple-query mode |
| Migration DSL     | Working — `create_collection` (with `bitemporal:` flag on v0.3.0+), `create_vector_index`, `drop_collection` |
| Model concerns    | Vector, Graph (with `graph_stats` on v0.3.0+), Timeseries, Spatial, KV, FTS |
| Ops surface       | `show_stats` / `show_metrics` / `show_memory` / `show_roles` / `show_tenant` / `show_tenants` / `set_tenant` (v0.3.0+) |
| Test suite        | 56 examples / 0 failures / 0 pending |
| Rails versions    | 7.1+, 8.x verified |
| Ruby versions     | 3.2+ (developed on 4.0.1) |
| NodeDB versions   | 0.1.x, 0.2.0, 0.2.1, **0.3.0** (latest retest 2026-06-07 — see *Known issues*) |
| Sample app        | [mkhairi/nodedb-on-rails](https://github.com/mkhairi/nodedb-on-rails) (Rails 8.1, full CRUD demo across every NodeDB engine + ops dashboard + personalized PageRank + bitemporal AuditLog) |

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
- NodeDB v0.1+ (pgwire on port 6432) — **v0.3.0 recommended**.
  Bundles `SHOW GRAPH STATS`, personalized PageRank, the
  `BITEMPORAL` collection modifier, an in-process pg_catalog
  evaluator (still narrow — see BUG-019), and the operational
  `SHOW ROLES / STATS / METRICS / MEMORY / TENANT` surface.
  - 2026-05-18 build: `fts` engine removed (use `create_fts`).
  - Post-2026-05-23 builds added a vquery pg_catalog evaluator
    that rejects four of the shapes AR's connection handshake
    needs. Adapter `0.1.0.alpha.7+` bypasses every affected catalog
    query on every transport (see BUG-019).
  - Dev environments running the post-`f9e19d84` lockout enforcement
    need `[auth] max_failed_logins = 0` in a TOML config; without it,
    the auth lockout state (persistent across daemon restart in
    `_system.lockout_state`) trips on routine probe sequences and
    surfaces as `FATAL: Password authentication failed`.

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
- [x] `create_fts(name, fulltext: [...])` — document_strict collection + `CREATE FULLTEXT INDEX` (NodeDB removed the `fts` engine)
- [x] `drop_collection` rescues missing-collection errors when `if_exists: true`
- [x] `create_collection ..., bitemporal: true` — NodeDB v0.3.0 `BITEMPORAL` collection modifier (writes work; reads currently blocked by upstream BUG-021)
- [x] `Model.graph_stats(verbose:, as_of:)` + `connection.graph_stats(collection:, verbose:, as_of:)` — NodeDB v0.3.0 `SHOW GRAPH STATS` with the upstream-scoping-bug Ruby fallback (see BUG-020)
- [x] `Graph#graph_algo(:pagerank, personalization: {...})` — NodeDB v0.3.0 personalized PageRank with Hash → JSON encoding (via nodedb-ruby `SQL::Graph.algo`)
- [x] `connection.show_stats / show_metrics / show_memory / show_roles / show_tenant / show_tenants / set_tenant` — operational SHOW surface; tenant identifier args validated through a strict allowlist to avoid SQL-injection through the bare-identifier interpolation
- [x] Sample Rails 8 app with full CRUD walkthrough: [mkhairi/nodedb-on-rails](https://github.com/mkhairi/nodedb-on-rails)

### Pending
- [ ] Auto-unwrap of schemaless `SELECT *` rows (currently returns
      `{ "result" => "<json>" }`)
- [ ] SQL rewriter to strip the `"table".col` qualifier so AR's default
      projection (`SELECT "articles".*`) returns flat columns
- [ ] Silence harmless `INSERT EDGE` `pg`-gem stderr warnings
- [ ] Generators (`rails g nodedb:collection`, `nodedb:vector_index`)
- [ ] Connection pool aware fixtures helper for RSpec
- [x] CHANGELOG.md
- [ ] gemspec push to RubyGems (currently consumed via `path:`)

## Known issues

NodeDB-side parser quirks and limits, grouped by status. Each is tracked
in `docs/bugs/`. Last retested: **2026-06-07** against **NodeDB v0.3.0**
(commit `25040fdf`).

### Resolved upstream

- **BUG-001** `ResourcesExhausted` on non-timeseries INSERT — fixed in
  `nodedb/src/config/engine.rs` + `memory/startup.rs`.
- **BUG-004** `DROP COLLECTION IF EXISTS` parser quirk — fixed in v0.2.1;
  adapter `drop_collection(if_exists:)` now emits the native form
  directly (rescue workaround retired in 0.1.0.alpha.3).
- **BUG-005** Prepared statements missing `RowDescription` — fixed
  upstream; adapter still uses simple-query mode for safety.
- **BUG-006** Boolean column OID 0 — fixed upstream; no `unknown OID`
  warnings emitted.
- **BUG-009** `INSERT` command tag missing OID slot — fixed in v0.2.1
  (`INSERT 0 N` form now emitted); no more libpq stderr noise on INSERT.
- **BUG-017** `SHOW server_version` stuck at `NodeDB 0.1.0` after upstream
  bump — fixed in v0.2.1 via upstream PR #114; wire version now sources
  from `crate::version::VERSION`.
- **BUG-010** `text_match()` didn't filter rows — fixed on the 2026-05-18
  build; it now filters server-side. `fts_search` bm25 null-drop
  workaround retired.
- **BUG-013** FTS fuzzy returned wrapped JSON — fixed on the 2026-05-18
  build; fuzzy now returns a flat projection. `fts_search` JSON-unwrap
  retired.
- **`fts` engine removed upstream** — FTS is a `document_strict`
  collection + `CREATE FULLTEXT INDEX`. Use `create_fts(name,
  fulltext: [...])`; legacy `engine: :fts` maps to `document_strict`.

### Adapter compensates transparently

You write idiomatic AR; the adapter swallows the workaround:

- **`schema_migrations` / `ar_internal_metadata` tables (#24)** — NodeDB-aware
  subclasses use `CREATE COLLECTION` + raw unqualified SQL. `rails
  db:migrate` and `migration_error: :page_load` work normally.
- **BUG-008** DELETE inside transaction silently dropped — `exec_delete`
  override commits + re-issues the DELETE outside the AR-opened
  transaction so `record.destroy` actually persists. PARTIAL fix in
  v0.2.1: NodeDB persists DELETE inside txn when the PK column lacks an
  explicit `NOT NULL` keyword, but AR's emitted DDL is always
  `"id" text NOT NULL PRIMARY KEY` — so the broken path still applies.
  Workaround stays.
- **GRAPH TRAVERSE** returns a single row with a JSON array — `Graph`
  concern parses automatically.
- **GRAPH INSERT EDGE** now requires `IN 'collection'` — `Graph` concern
  threads `in_collection:` automatically.
- **BUG-007** `pg_attribute` query returns duplicate `id` row — adapter
  uses `DESCRIBE` fallback in `column_definitions`. Reshaped by BUG-019
  (vquery refactor) — adapter behaviour unchanged.
- **BUG-019** vquery pg_catalog evaluator rejects `::regclass` casts,
  joins across virtual tables, `ANY(current_schemas(false))`, and
  `pg_type.typelem`. Adapter routes `tables`, `primary_keys`,
  `pk_and_sequence_for`, `indexes`, `foreign_keys`,
  `check_constraints` through NodeDB-native paths (SHOW COLLECTIONS /
  DESCRIBE / `[]`), and treats `load_additional_types` as a no-op on
  every transport.
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

### Open / limited workaround (v0.3.0 retest 2026-06-07)

- **BUG-002** `SELECT version()` returns empty — adapter uses
  `SHOW server_version` instead.
- **BUG-003** `PQserverVersion()` raises `PG::ConnectionBad` — adapter
  hardcodes `160000` for `database_version` / `get_database_version`.
- **BUG-008** DELETE-in-txn — v0.3.0 psql probe with
  `INT NOT NULL PRIMARY KEY` persists the DELETE inside `BEGIN/COMMIT`,
  but AR's `record.destroy` against a `document_strict` collection with
  a text PK still no-ops on both pgwire and native. The `exec_delete`
  override stays until upstream lands the document_strict + text-PK
  path too.
- **BUG-011** Spatial INSERT with `ST_GeomFromText` — hard parse error
  (`unsupported: value expression: ST_GeomFromText(...)`). Spatial
  engine still unusable for real coordinate work. Sample app uses
  `document_strict` with explicit `lat FLOAT, lon FLOAT` columns and
  computes haversine in Ruby.
- **BUG-012** Spatial engine drops non-geometry typed columns silently
  on INSERT. Combined with BUG-011, no working storage path exists in
  the spatial engine today.
- **BUG-014** `pg_try_advisory_lock` / `pg_advisory_unlock` — v0.3.0
  parser recognises the functions but they return empty rows instead
  of booleans. Adapter `get_advisory_lock` / `release_advisory_lock`
  no-op stubs still required.
- **BUG-015** DROP+CREATE in the retention window resurrects rows from
  the prior incarnation of the collection. Use `UNDROP COLLECTION name`
  then `DELETE FROM name` to clear, or wait for the retention window
  to expire. `bin/setup` in the sample app reconciles this for
  `schema_migrations` automatically.
- **BUG-016** `document_strict` 2nd INSERT collides on empty `id` when
  primary key is on a non-`id` column. v0.3.0's `_rowid` surrogate fix
  does **not** resolve this — bug reproduces with and without explicit
  PK. Adapter stores user keys in the built-in `id` column for
  `schema_migrations` / `ar_internal_metadata` to sidestep this.
- **BUG-018** Native transport returns document-backed rows as raw
  `{data,id}` blobs. Document model unwraps client-side; KV reads fail
  with `KeyError "value"`; vector search fails with
  `TypeError: no implicit conversion of nil into String`.
  Sample app `feature_smoke.rb` is 17/19 over native, 21/21 over pgwire.
- **BUG-019** vquery pg_catalog evaluator rejects `::regclass` casts,
  joins across virtual tables, `ANY(current_schemas(false))`, and
  `pg_type.typelem`. Adapter routes `tables`, `primary_keys`,
  `pk_and_sequence_for`, `indexes`, `foreign_keys`,
  `check_constraints` through NodeDB-native paths (SHOW COLLECTIONS /
  DESCRIBE / `[]`), and treats `load_additional_types` as a no-op on
  every transport. v0.3.0's in-process pg_catalog evaluator does
  not cover any of the four shapes AR needs.
- **BUG-020** `SHOW GRAPH STATS '<collection>'` returns all-zero
  counters even when the tenant-wide form proves the collection has
  edges. `Model.graph_stats` falls back to the tenant-wide form and
  filters in Ruby on `table_name`. `connection.graph_stats` issues
  the SQL verbatim — callers can use it to reproduce the upstream bug.
- **BUG-021** `BITEMPORAL` collections accept INSERTs but every SELECT
  shape (plain, scoped, `AS OF SYSTEM TIME NOW()`,
  `AS OF SYSTEM TIME <ms>`) returns zero rows. The
  `create_collection ..., bitemporal: true` DDL surface ships in
  `0.1.0.alpha.8` so migrations are ready when upstream lands the
  read path; today bitemporal collections are effectively write-only.

## License

Released under the **BSD 2-Clause License**. Full text: [LICENSE.md](LICENSE.md).

Independent third-party adapter. Not affiliated with, endorsed by, or
maintained by the NodeDB project. "NodeDB" is referenced solely to identify
the database this gem connects to.
