# Changelog

All notable changes to `activerecord-nodedb-adapter` are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-`1.0` alpha line: APIs may change between alpha releases without
deprecation. Bump `N` in `0.1.0.alpha.N` for any user-visible change.

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
