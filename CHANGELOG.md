# Changelog

All notable changes to `activerecord-nodedb-adapter` are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-`1.0` alpha line: APIs may change between alpha releases without
deprecation. Bump `N` in `0.1.0.alpha.N` for any user-visible change.

## [0.1.0.alpha.8] — 2026-06-07

NodeDB v0.3.0 (commit `25040fdf`) compatibility release. Surfaces the
new server-side features (persistent graph-stats, operational SHOW
commands, BITEMPORAL collections) and patches a security finding from
the background commit review.

Requires `nodedb-ruby >= 0.1.0.alpha.5`.

### Added
- **`Model.graph_stats(verbose:, as_of:)`** + **`connection.graph_stats(collection:, verbose:, as_of:)`** — surfaces NodeDB v0.3.0's persistent O(1) edge-store counters via `SHOW GRAPH STATS [<collection>] [VERBOSE] [AS OF SYSTEM TIME <ms>]`. Compact form yields one row with `collection`, `node_count`, `edge_count`, `distinct_label_count`, `labels` (JSON-encoded `{label, count}` array); verbose form yields one row per `(collection, label)` pair. The model-level helper currently fetches the tenant-wide form and filters in Ruby on `table_name` (see BUG-020 — scoped form returns zeros upstream). (#55)
- **Operational SHOW helpers on `NodedbAdapter`**: `show_roles`, `show_stats`, `show_metrics`, `show_memory`, `show_tenant(id_or_name)`, `show_tenants(name_filter)`, plus the superuser-only `set_tenant(value)` (accepts `nil` / `:default` / `"default"` / Integer / String). All return `Array<Hash>` or a single `Hash`. (#58)
- **`create_collection ..., bitemporal: true`** — passes NodeDB v0.3.0's `BITEMPORAL` modifier through to the column-list parens. Note: v0.3.0's bitemporal SELECT path still emits document rows in the raw `{data,id}` blob shape over both transports (BUG-018 territory) so the AR Relation experience is degraded — documented inline in the method comment. (#60)

### Security
- **`show_tenant` and `show_tenants` argument validation.** PR #58 interpolated user-supplied String tenant names directly into the SHOW command tail; NodeDB consumes the name as a bare identifier and applies no SQL-string quoting on the parser side, so naive interpolation was a HIGH-severity SQLi vector flagged by the background commit review. Inputs are now matched against `/\A[A-Za-z0-9_][A-Za-z0-9_\-]*\z/` (private `validate_tenant_identifier!`); non-matching strings raise `ArgumentError`. The `Integer` path is unchanged (already safe). (#59)

### Documentation
- **BUG-020 — `SHOW GRAPH STATS '<collection>'` scoping returns zero counters.** New `docs/bugs/020-show-graph-stats-scoping-zeros.md` capturing repro, expected behaviour, adapter workaround, and retirement criteria; cross-linked from `docs/bugs/README.md`. Tracking issue #57. (#56)
- **Bug log refreshed to v0.3.0.** `docs/bugs/README.md` header, transport-parity table, and the status / workarounds cells for BUG-008, BUG-014, BUG-019. (#54)

### Bug retest summary (v0.3.0, commit `25040fdf`)
| Bug | Status | Workaround |
| --- | ------ | ---------- |
| 002 / 003 | OPEN | hardcoded version (`160000`) + `SHOW server_version` |
| 007 | RESHAPED by 019 | `DESCRIBE` bypass |
| 008 | PARTIAL — psql persists `INT NOT NULL PK` DELETE in txn; AR `document_strict` + text-PK `record.destroy` still no-ops on both pgwire and native | `exec_delete` override **kept** |
| 011 / 012 | OPEN (hard error on `ST_GeomFromText`) | sample app uses `document_strict` + Ruby haversine |
| 014 | PARTIAL — advisory locks parsed, still return zero rows (not boolean) | no-op stub pair **kept** |
| 015 | OPEN — DROP+CREATE retention window still resurrects rows | sample-app `bin/setup` reconcile |
| 016 | OPEN — even without explicit PK, 2nd INSERT collides on empty `id` (`_rowid` fix does not resolve it) | built-in `id` PK on `SchemaMigration` / `InternalMetadata` **kept** |
| 018 | OPEN — native KV `KeyError "value"` + vector `TypeError nil` unchanged | no adapter workaround |
| 019 | OPEN — all four vquery shapes still rejected by the in-process evaluator | unconditional bypass **kept** |
| 020 (new) | OPEN — `SHOW GRAPH STATS '<col>'` returns zeros | tenant-wide + Ruby filter |

Adapter suite: 56 examples, 0 failures.

## [0.1.0.alpha.7] — 2026-05-24

### Fixed
- **BUG-019 — pg_catalog vquery bypass.** NodeDB upstream rewrote the
  pgwire pg_catalog handlers to go through an in-process `vquery`
  evaluator (commits `eed703c6` / `2330063a`, 2026-05-23). The
  evaluator's column set and expression vocabulary are narrower than
  what AR emits during connection setup and schema reflection — it
  rejects `::regclass` casts, joins across virtual tables,
  `ANY(current_schemas(false))` predicates, and references to
  `pg_type.typelem`. AR closed the broken connection mid-handshake
  and NodeDB counted the close as an auth failure, masking the root
  cause as `FATAL: Password authentication failed`. The native-only
  bypasses already in `NodedbAdapter` (BUG-018 territory) now apply
  on every transport:
  - `load_additional_types` — unconditional no-op (was native-only).
    Base types come from `initialize_type_map`'s static section.
  - `tables` / `data_sources` — `collections` (SHOW COLLECTIONS) on
    every transport.
  - `primary_keys` — `["id"]` when the collection has an `id`
    column, else `[]`.
  - `pk_and_sequence_for` — `nil` (NodeDB has no sequences).
  - `indexes`, `foreign_keys`, `check_constraints` — `[]`.
  - `add_pg_decoders` keeps the native-only skip — vquery's
    materialised `pg_type` columns are sufficient for the decoder
    fast-path.

### Documentation
- New `docs/bugs/019-vquery-pg-catalog-narrow-shapes.md` capturing the
  expression shapes the evaluator rejects, the auth-failure masking,
  the dev-only `max_failed_logins = 0` config workaround for
  upstream's tightened lockout enforcement (`f9e19d84`), and the
  retirement criteria.
- `docs/bugs/README.md` refreshed for the 2026-05-24 build (commit
  `2aaec0fd`). BUG-007 marked **RESHAPED** by BUG-019 — pg_attribute
  still goes through the adapter's `DESCRIBE` fallback so the change
  is transparent to callers.

## [0.1.0.alpha.6] — 2026-05-18

### Added
- `create_fts(name, fulltext: [...])` migration helper — builds a
  `document_strict` collection then a `CREATE FULLTEXT INDEX` per
  `fulltext:` column (named `<collection>_<column>_ft`).
- `create_fulltext_index(name, on:, column:)` /
  `drop_fulltext_index(name)` schema statements. Drop emits the generic
  `DROP INDEX` (NodeDB has no `DROP FULLTEXT INDEX`) and is idempotent.

### Changed
- **FTS engine removed upstream** (post-`v0.2.1` build, commit
  `a178aa5b`). `create_collection engine: :fts` now maps to
  `document_strict` (via `nodedb-ruby` ≥ 0.1.0.alpha.4) instead of
  emitting an invalid `WITH (engine='fts')`.
- `nodedb-ruby` dependency floor raised to `>= 0.1.0.alpha.4` (FTS
  index builders + `:fts`→`document_strict` mapping live there).

### Removed
- **BUG-010 / BUG-013 workarounds retired.** `text_match()` now filters
  rows server-side and fuzzy mode returns a flat projection on the
  2026-05-18 upstream build. `NodeDB::FullTextSearch#fts_search` no
  longer projects/filters `bm25_score`, no longer JSON-unwraps fuzzy
  rows, and no longer orders by bm25 (it was `0.0`/`nil` on small
  corpora). It issues `SELECT id … WHERE text_match()` and returns
  `[{ "id" => }]` (the `"score"` key is gone — bm25 was never a
  meaningful relevance signal here).

### Tests
- New `spec/full_text_search_spec.rb`: `create_fts` builds the
  collection + index; `text_match` returns only matching rows
  (BUG-010 regression guard); empty result on no match;
  `drop_fulltext_index` idempotent. Suite 34 → 38.

## [0.1.0.alpha.5] — 2026-05-18

### Fixed
- **Native graph traverse regression.** A post-`v0.2.1` upstream build
  returns `GRAPH TRAVERSE` as a single `result` cell holding a
  `{"nodes":[...],"edges":[...]}` object. The PR #49 document-blob
  normaliser's "single Hash → columns" branch promoted that object into
  `nodes`/`edges` columns, so `NodeDB::Graph#graph_traverse`'s
  `fetch("result")` missed and traversal returned `[]` over
  `transport: native`. Graph-shaped `result` payloads (`nodes`/`edges`
  keys) now pass through the normaliser untouched. pgwire unaffected.

### Changed
- BUG-018 doc + transport-parity matrix refreshed against the
  2026-05-18 upstream build (commit `a178aa5b`): native FTS
  search/fuzzy now **PASS** (upstream now projects `bm25_score`),
  native spatial still PASS, graph fixed adapter-side. Native
  feature_smoke 14/19 → **17/19**; pgwire 21/21. KV read + vector
  search remain the open native gap. BUG-002 / BUG-014 / BUG-015
  rechecked, unchanged.

### Tests
- `native_pg_compat_spec`: cover both `["result"]` shapes — JSON
  array-of-objects expands to columns; a `{nodes,edges}` graph payload
  passes through untouched (regression guard). Suite 32 → 34.

## [0.1.0.alpha.4] — 2026-05-16

### Added
- **Opt-in native transport.** Set `transport: native` in the database
  config to talk to NodeDB over its binary MessagePack protocol
  (port 6433, via `nodedb-ruby`'s `NodeDB::Native::Connection`) instead
  of pgwire/libpq. A `NativePGCompat` shim exposes the slice of the
  PG::Connection / PG::Result API that Rails 8.1's PostgreSQLAdapter
  uses, so models, schema, CRUD, transactions and the BUG-008
  `record.destroy` workaround all work over native. Default transport is
  unchanged (`:pg`, port 6432) — existing apps and the pgwire suite are
  untouched.

### Notes
- On native, pg catalog reflection (`pg_class`/`pg_type`/`pg_index`) is
  unavailable; schema reflection falls back to NodeDB `DESCRIBE` /
  `SHOW COLLECTIONS` and model attribute casting is schema-driven (as it
  already was). Per-result PG OIDs aren't available over native, so ad-hoc
  SQL values come back as strings — model attributes still cast via the
  collection schema.
- Requires `nodedb-ruby >= 0.1.0.alpha.3` (native client).

## [0.1.0.alpha.3] — 2026-05-15

### Removed
- **BUG-004 workaround retired.** `drop_collection(if_exists: true)` now
  emits `DROP COLLECTION IF EXISTS` directly via
  `NodeDB::SQL::Collection.drop_if_exists` instead of rescuing a "does not
  exist" `StatementInvalid`. Both code paths verified against NodeDB
  v0.2.1.

### Changed
- **BUG-008 status walked back from RESOLVED to PARTIAL.** Re-retest
  discovered NodeDB v0.2.1's DELETE-in-txn fix is conditional on column
  schema: works for implicit `NOT NULL`, still silently drops the row
  when the PK column is declared with explicit `NOT NULL` — which is
  exactly what ActiveRecord emits. `exec_delete` override **stays** and
  is now documented as load-bearing on v0.2.1+. Bug doc + tracking issue
  updated.
- `graph_traverse` unwraps NodeDB v0.2.x's new
  `{"nodes":[{"id":...,"depth":N}], "edges":[...]}` response shape back
  into the documented `Array<String>` of node IDs, with the starting
  node filtered out. v0.1.x array-of-IDs payloads still pass through.

### Fixed
- Graph specs (`spec/graph_spec.rb`) updated to assert against the v0.2.x
  payload shape via the new `graph_traverse` unwrap path.

### Added
- Specs covering `drop_collection(if_exists: true)` for both missing and
  existing collection paths.
- Spec covering `record.destroy` under the BUG-008 conditional fix —
  asserts the `exec_delete` override still produces the expected
  "DELETE persists" semantics on collections AR's DDL emits.

## [0.1.0.alpha.2] — 2026-05-15

### Added
- Per-engine migration helpers: `create_timeseries`, `create_kv`,
  `create_columnar`, `create_spatial`, `create_document_strict`; plus
  `drop_vector_index`. ([#19])
- `connection.with_settings { ... }` — block-scoped NodeDB session
  variables. ([#20])
- Quoting hooks: `Array<Numeric>` → VECTOR literal, `Hash` → JSON
  literal. ([#21])
- `engine_options:` kwarg threaded through `create_collection` into the
  `WITH (...)` clause. ([#22])
- NodeDB-aware `SchemaMigration` + `InternalMetadata` so
  `rails db:migrate` / `db:rollback` / `db:migrate:status` / `db:seed`
  and the dev-mode `migration_error: :page_load` check all work against
  `schema_migrations` / `ar_internal_metadata` collections. ([#24])
- Type casters registered at connection bootstrap:
  `attribute :col, :vector` / `:json` / `:geometry`. ([#18])
- `Nodedb::SchemaDumper` — engine-aware `db/schema.rb` output. ([#26])
- `Nodedb::DatabaseTasks` registry so Rails 8 `db:*` rake tasks run
  cleanly. ([#37])

### Fixed
- `Graph.silence_libpq_noise` filter for harmless libpq stderr noise on
  `INSERT EDGE` / `GRAPH ...` command tags. ([#5])
- `record.destroy` now persists under NodeDB BUG-008
  (DELETE-in-transaction silently dropped); `exec_delete` re-issues the
  DELETE outside the AR-opened transaction. ([#10])
- KV column refs no longer rejected — bypass AR's automatic
  table-qualified column quoting that NodeDB rejects. ([#11])
- FTS row filtering: drop rows where `bm25_score` is nil/zero
  (BUG-010 workaround). ([#15])
- FTS fuzzy mode: keep zero scores and unwrap the single `result` column
  that NodeDB returns as wrapped JSON (BUG-013 workaround). ([#17])
- `rails db:migrate` / `db:rollback` end-to-end against NodeDB. ([#30])

### Changed
- README and bug log refreshed for NodeDB v0.2.1 retest:
  - **Resolved upstream:** BUG-004 (`DROP COLLECTION IF EXISTS`),
    BUG-008 (DELETE-in-txn), BUG-009 (`INSERT 0 N` command tag form),
    BUG-017 (`SHOW server_version` stuck at 0.1.0).
  - **CHANGED:** BUG-011 — spatial `ST_GeomFromText` now hard-errors
    instead of silently storing literal text. Spatial engine still
    unusable for real coordinates.
  - **PARTIAL:** BUG-014 — `pg_try_advisory_lock` /
    `pg_advisory_unlock` parsed but return empty rows; adapter no-op
    stub still required.
  - Adapter workarounds for BUG-004 / 008 / 009 / 017 remain in tree for
    compatibility with older NodeDB binaries; retire when adapter drops
    pre-0.2.1 support (likely at beta). ([#40], [#41])
- New bug docs: BUG-014, BUG-015 (DROP+CREATE retention window),
  BUG-016 (`document_strict` non-`id` PK collision). ([#35])
- `CLAUDE.md` slimmed to defer to the workspace root for shared
  branch/PR/commit conventions. ([#29])

### Docs
- Installation snippets switched to Bundler `github:` shorthand. ([#28])
- Sample app references point at
  [`mkhairi/nodedb-on-rails`](https://github.com/mkhairi/nodedb-on-rails). ([#36])
- Type casters, per-engine helpers, `with_settings`, and
  `engine_options:` covered in the README usage section. ([#23])
- BUG-017 reproduction, expected behaviour, and adapter impact
  documented in `docs/bugs/017-*.md`. ([#39])

### Internal
- Relative path references corrected after the move into `./gems/`. ([#7])

## [0.1.0.alpha.1] — 2026-05-09

Initial alpha. Rails ActiveRecord adapter for NodeDB, extending
`PostgreSQLAdapter`.

### Added
- Connection adapter registered under `adapter: nodedb`.
- Simple-query mode (NodeDB lacks extended-query `RowDescription`).
- `database_version` stub returning `160000` so AR's PostgreSQL guards
  pass.
- `nodedb_version` introspection via `SHOW server_version`.
- Initial migration DSL: `create_collection`, `create_vector_index`,
  `drop_collection(if_exists:)`.
- Model concerns: `NodeDB::Vector`, `Graph`, `Timeseries`, `Spatial`,
  `KV`, `FullTextSearch`.
- Advisory-lock stubs (`get_advisory_lock` / `release_advisory_lock`
  return `true`) — BUG-014 workaround.
- Upstream bug log seeded.

[0.1.0.alpha.7]: https://github.com/mkhairi/activerecord-nodedb-adapter/compare/v0.1.0.alpha.6...v0.1.0.alpha.7
[0.1.0.alpha.6]: https://github.com/mkhairi/activerecord-nodedb-adapter/compare/v0.1.0.alpha.5...v0.1.0.alpha.6
[0.1.0.alpha.5]: https://github.com/mkhairi/activerecord-nodedb-adapter/compare/v0.1.0.alpha.4...v0.1.0.alpha.5
[0.1.0.alpha.4]: https://github.com/mkhairi/activerecord-nodedb-adapter/compare/v0.1.0.alpha.3...v0.1.0.alpha.4
[0.1.0.alpha.3]: https://github.com/mkhairi/activerecord-nodedb-adapter/compare/v0.1.0.alpha.2...v0.1.0.alpha.3
[0.1.0.alpha.2]: https://github.com/mkhairi/activerecord-nodedb-adapter/compare/v0.1.0.alpha.1...v0.1.0.alpha.2
[0.1.0.alpha.1]: https://github.com/mkhairi/activerecord-nodedb-adapter/releases/tag/v0.1.0.alpha.1

[#5]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/5
[#7]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/7
[#10]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/10
[#11]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/11
[#15]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/15
[#17]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/17
[#18]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/18
[#19]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/19
[#20]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/20
[#21]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/21
[#22]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/22
[#23]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/23
[#24]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/24
[#26]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/26
[#28]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/28
[#29]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/29
[#30]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/30
[#35]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/35
[#36]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/36
[#37]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/37
[#39]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/39
[#40]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/40
[#41]: https://github.com/mkhairi/activerecord-nodedb-adapter/pull/41
