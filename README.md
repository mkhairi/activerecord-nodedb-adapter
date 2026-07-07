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

SocialNode.graph_insert_edge(from: "alice", to: "bob", type: "follows",
                             properties: { since: 2020 })
SocialNode.graph_traverse(from: "alice", depth: 3)
# => ["bob", "carol", ...]
SocialNode.graph_delete_edge(from: "alice", to: "bob", type: "follows")

# PageRank — pass personalization: to bias the seed vector
SocialNode.graph_algo(:pagerank, damping: 0.85, iterations: 20)
SocialNode.graph_algo(:pagerank, personalization: { "alice" => 1.0 })

# Persistent O(1) edge-store counters, scoped to this model's collection
SocialNode.graph_stats
# => [{ "collection" => "social_nodes", "node_count" => "4",
#       "edge_count" => "2", "distinct_label_count" => "1",
#       "labels" => "[{\"count\":2,\"label\":\"follows\"}]" }]
SocialNode.graph_stats(verbose: true)   # one row per (collection, label)
SocialNode.graph_stats(as_of: 1.hour.ago.to_i * 1000)

# Tenant-wide form via the connection helper
ActiveRecord::Base.connection.graph_stats
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

### Bitemporal collections

NodeDB retains every committed version of each row in a `BITEMPORAL`
collection. Current-state reads and writes are plain ActiveRecord
(`create!` / `update!` / `destroy` all persist and version); the
`NodeDB::Bitemporal` concern exposes the system-time read surface:

```ruby
# migration
create_collection :audit_logs, engine: :document_strict, bitemporal: true do |t|
  t.text :id, primary_key: true
  t.text :actor
  t.text :recorded_at
end

class AuditLog < ApplicationRecord
  include NodeDB::Bitemporal
end
```

```ruby
AuditLog.where(actor: "alice")   # current state, plain AR
AuditLog.versions                # every committed version, oldest first,
                                 # each row carrying `_ts_system` (commit ms)
AuditLog.history("log-42")       # one record's version trail
AuditLog.as_of(1.hour.ago)       # rows current at that instant (Time or ms)
```

Time-travel rows come back as `Array<Hash>` — the `AS OF SYSTEM TIME`
scan suffix doesn't compose with AR relations, and history rows carry
the extra `_ts_system` column.

One upstream sharp edge remains: don't DROP + CREATE a bitemporal
collection under the same name (the old version history resurrects,
BUG-028). Details in [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md).

## Idiomatic querying

Hash-conditions, conditional counts, and qualified projections work
as-is — the adapter rewrites AR's table-qualified SQL on single-table
statements before dispatch (NodeDB silently matches zero rows for
qualified refs otherwise; see BUG-025 in the known issues):

```ruby
Article.where(title: "hello")             # works
Article.where(score: 5..10).count         # works
Article.find_by(title: "hello")           # works
Article.where("score >= ?", 5)            # raw fragments: keep columns unqualified
```

## Operational helpers

Server counters, memory budgets, roles, and tenant info over plain
connection methods:

```ruby
conn = ActiveRecord::Base.connection
conn.show_stats     # => [{ "name" => "queries_total", "value" => "42" }, ...]
conn.show_metrics   # extended Prometheus-style counters
conn.show_memory    # per-engine memory budget snapshot
conn.show_roles     # defined roles
conn.show_tenant(0) # current tenant snapshot
conn.nodedb_version # => "0.3.0" (parsed from SHOW server_version)
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
unknown columns are silently dropped). Block-form columns work with
every helper:

```ruby
create_document_strict :articles do |t|
  t.text    :id, primary_key: true
  t.text    :title
  t.text    :body
  t.integer :score
end
```

Natural keys on non-`id` columns work on current upstream:

```ruby
create_collection :products, engine: :document_strict, id: false do |t|
  t.text :sku, primary_key: true
  t.text :label
end
```

### Generators

```bash
rails g nodedb:collection articles title:text score:float embedding:vector{384} geom:geometry
rails g nodedb:collection audit_logs actor:text --engine=document_strict --bitemporal
rails g nodedb:vector_index articles embedding --dim=384 --metric=cosine
```

`nodedb:collection` emits a `create_collection` migration (vector
columns take the dim from the `field:vector{dim}` limit syntax);
`nodedb:vector_index` emits a reversible `create_vector_index` /
`drop_vector_index` migration named `idx_<collection>_<column>`.

### NodeDB column types

Migration blocks accept NodeDB-typed column methods alongside the
standard AR ones:

```ruby
create_document_strict :articles do |t|
  t.text     :id, primary_key: true
  t.text     :title
  t.vector   :embedding, dim: 384   # VECTOR(384)
  t.geometry :geom                  # GEOMETRY
end
```

`t.vector` requires `dim:`. Both are shorthand for the raw-SQL column
form (`t.column :embedding, "VECTOR(384)"`), which keeps working.

Notes: AR's `t.datetime` emits `TIMESTAMP(6)`, which NodeDB rejects —
use `t.column :at, "TIMESTAMP"` for timestamp columns. Integer
`SERIAL` primary keys don't exist (no sequences); use text/UUID keys
with a `before_create { self.id ||= SecureRandom.uuid }`.

## Type casters

Engine-specific Ruby <-> NodeDB-literal casting is registered automatically
on connection bootstrap. Declare attributes on your model and AR rounds
them through the right Ruby type:

```ruby
class Article < ApplicationRecord
  attribute :embedding, :vector       # Array<Float>     <-> "[0.1, 0.2, ...]"
  attribute :payload,   :json         # Hash / Array     <-> JSON string
  attribute :geom,      :geometry     # WKT string passthrough (write path
                                      # works upstream via ST_GeomFromText /
                                      # ST_MakePoint; read-side accessors
                                      # still pending — see known issues)
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
- Lookup keys (versions, metadata keys) live in NodeDB's built-in `id`
  column. (Historical: non-`id` PKs used to collide upstream; fixed on
  current builds, the convention stays because it's harmless.)
- DELETE path uses the BUG-008 workaround (re-issue outside the AR
  transaction) so `db:rollback` never sees the stale point-lookup
  phantom.

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
- NodeDB (pgwire on port 6432) — **latest upstream `main` recommended**
  (verified against `8e84501a`, post-v0.3.0). Brings document restart
  durability, qualified-WHERE and GROUP-BY-alias evaluation (both
  adapter rewrites retired), graph collection scoping, multi-database
  catalog reads, native KV/vector parity, and unified engine-clause
  spellings. Adapter still bypasses AR's pg_catalog introspection
  (see the BUG-019 tracking issue), and this head carries fresh
  regressions around scalar aggregates and filtered history reads —
  see `docs/KNOWN_ISSUES.md`.
  - On-disk format changed vs pre-June builds — old data dirs make
    the daemon panic at boot; start with a fresh data directory.
  - `fts` engine removed upstream (use `create_fts`).
  - Dev environments need `[auth] max_failed_logins = 0` in a TOML
    config; without it, persistent lockout state trips on routine
    probe sequences and surfaces as
    `FATAL: Password authentication failed`.

## Feature checklist

### Implemented
- [x] Connection adapter that registers under `adapter: nodedb`
- [x] Simple-query mode (NodeDB does not implement extended-query
      `RowDescription` for prepared statements)
- [x] `database_version` derived from `current_setting('server_version_num')`
      (fallback `160000` for older builds) so AR's PG version guards pass
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
- [x] `record.destroy` persists transactionally with no adapter override
      (the BUG-008 re-issue workaround was retired after the upstream
      transactional DELETE/PUT rework)
- [x] `Graph.silence_libpq_noise` filter for harmless libpq stderr warnings
- [x] `create_fts(name, fulltext: [...])` — document_strict collection + `CREATE FULLTEXT INDEX` (NodeDB removed the `fts` engine)
- [x] `drop_collection` rescues missing-collection errors when `if_exists: true`
- [x] `create_collection ..., bitemporal: true` — NodeDB `BITEMPORAL` collection modifier; AR models read and write bitemporal collections (upstream BUG-024 fixed). Caveat on current upstream: filtered history reads (`AS OF ... WHERE`) return empty — BUG-038
- [x] `Model.graph_stats(verbose:, as_of:)` + `connection.graph_stats(collection:, verbose:, as_of:)` — `SHOW GRAPH STATS`, scoped form (upstream scoping fixed; Ruby fallback retired)
- [x] `Graph#graph_algo(:pagerank, personalization: {...})` — NodeDB v0.3.0 personalized PageRank with Hash → JSON encoding (via nodedb-ruby `SQL::Graph.algo`)
- [x] `connection.show_stats / show_metrics / show_memory / show_roles / show_tenant / show_tenants / set_tenant` — operational SHOW surface; tenant identifier args validated through a strict allowlist to avoid SQL-injection through the bare-identifier interpolation
- [x] Sample Rails 8 app with full CRUD walkthrough: [mkhairi/nodedb-on-rails](https://github.com/mkhairi/nodedb-on-rails)
- [x] Migration column methods: `t.vector :embedding, dim: 384` and
      `t.geometry :geom` work inside `create_collection` / `create_table`
      blocks (previously required `t.column :embedding, "VECTOR(384)"`)
- [x] `insert_all` / `insert_all!` / `upsert_all` — inherited PG batch
      paths verified on live NodeDB (single multi-row VALUES statement;
      conflict skip + upsert update honoured). Caveat: `returning:` data
      is always empty (NodeDB sends no RETURNING payload)

### Pending
- [ ] Auto-unwrap of schemaless `SELECT *` rows (currently returns
      `{ "result" => "<json>" }`)
- [ ] Silence harmless `INSERT EDGE` `pg`-gem stderr warnings
- [x] Generators (`rails g nodedb:collection`, `nodedb:vector_index`)
- [ ] Connection pool aware fixtures helper for RSpec
- [x] CHANGELOG.md
- [ ] gemspec push to RubyGems (currently consumed via `path:`)

## Known issues

Moved to [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md) — NodeDB-side
quirks grouped by user impact (resolved upstream, adapter-compensated,
requires awareness, open). Per-bug reproductions and workaround history
live in the [issue tracker](https://github.com/mkhairi/activerecord-nodedb-adapter/issues?q=%22%5Bupstream%3ANodeDB%5D%22)
(titles prefixed `[upstream:NodeDB] BUG-NNN`). Last retested 2026-07-07
against upstream `8e84501a`.

## License

Released under the **BSD 2-Clause License**. Full text: [LICENSE.md](LICENSE.md).

Independent third-party adapter. Not affiliated with, endorsed by, or
maintained by the NodeDB project. "NodeDB" is referenced solely to identify
the database this gem connects to.
