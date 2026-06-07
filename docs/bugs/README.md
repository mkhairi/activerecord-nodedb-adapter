# NodeDB upstream bug log

NodeDB-side bugs the adapter has had to dance around. Each entry has a
matching `<id>-<slug>.md` doc with reproduction, expected behaviour, and
adapter workaround.

Last refreshed: **2026-06-07** against the **v0.3.0** upstream release
(commit `25040fdf`; `SHOW server_version` reports `NodeDB 0.3.0`). Upstream
landed 21 commits since `2aaec0fd`, including an in-process pg_catalog
evaluator (still narrow — see BUG-019 below), personalized PageRank,
hybrid-search prefiltering with `allowed_ids`, linear-weight RRF fusion,
and bitemporal documents.

| ID  | Title | Status |
| --- | ----- | ------ |
| 001 | INSERT returns `ResourcesExhausted` on non-timeseries engines | RESOLVED — fixed in nodedb v0.2.0 (`EngineConfig` covers all 15 engines) |
| 002 | `SELECT version()` returns empty | OPEN — adapter uses `SHOW server_version` |
| 003 | `PQserverVersion()` raises `PG::ConnectionBad` | OPEN — adapter hardcodes `160000` |
| 004 | `DROP COLLECTION IF EXISTS` parses `IF` as a name when collection exists | **RESOLVED** in v0.2.1 — adapter now emits `DROP COLLECTION IF EXISTS` directly (workaround retired) |
| 005 | Prepared statements missing `RowDescription` before `DataRow` | RESOLVED |
| 006 | Unknown OID `0` for boolean column | RESOLVED |
| 007 | `pg_attribute` query returns duplicate `id` row | RESHAPED by [BUG-019](019-vquery-pg-catalog-narrow-shapes.md) — vquery refactor changes pg_attribute behaviour; adapter still bypasses via `DESCRIBE` |
| 008 | DELETE inside transaction silently dropped | **PARTIAL** through v0.3.0 — psql probe with `INT NOT NULL PRIMARY KEY` persists DELETE in txn on `25040fdf`, but AR's `record.destroy` path on `document_strict` with text PK still no-ops on both pgwire and native; `exec_delete` workaround still required |
| 009 | INSERT command tag missing OID slot | **RESOLVED** in v0.2.1 — `INSERT 0 N` form now emitted |
| 010 | `text_match()` predicate doesn't filter rows | **RESOLVED** upstream (2026-05-18 build) — filters server-side; adapter bm25 workaround retired |
| 011 | Spatial INSERT does not evaluate `ST_GeomFromText` | CHANGED — now hard error (was silent text store); spatial engine still unusable |
| 012 | Spatial engine drops non-geometry typed columns on INSERT | OBSCURED by 011 (cannot INSERT to test) |
| 013 | FTS fuzzy mode returns wrapped JSON | **RESOLVED** upstream (2026-05-18 build) — flat projection in fuzzy mode; adapter unwrap retired |
| 014 | `pg_try_advisory_lock` / `pg_advisory_unlock` missing | PARTIAL through v0.3.0 — parsed, still return zero rows (not boolean); adapter stubs still required |
| 015 | DROP + CREATE resurrects old rows in retention window | OPEN — sample app reconciles in `bin/setup` |
| 016 | `document_strict` 2nd INSERT collides on empty `id` when PK on non-`id` column | OPEN — adapter stores user keys in built-in `id` column (PR #24) |
| 017 | `SHOW server_version` stuck at "NodeDB 0.1.0" | **RESOLVED** in v0.2.1 (upstream PR #114) |
| 018 | Native protocol returns document-backed rows as a raw `{data,id}` blob (no virtual-column projection); pgwire unaffected | OPEN — `transport: native` only; no adapter workaround yet |
| 019 | vquery pg_catalog evaluator rejects regclass casts, joins, `ANY(current_schemas)` and `pg_type.typelem` (post-`2330063a` 2026-05-23 upstream) | OPEN through v0.3.0 — re-probed 2026-06-07 against `25040fdf`; all four shapes still rejected by the in-process evaluator. Adapter bypass retained in `0.1.0.alpha.7+` |
| 020 | `SHOW GRAPH STATS '<collection>'` returns all-zero counters even when the tenant-wide form proves the collection has edges (v0.3.0 release `25040fdf`) | OPEN through v0.3.0 — adapter's `NodeDB::Graph#graph_stats` falls back to the tenant-wide form + Ruby filter on `table_name` |

## Transport parity (pgwire vs native) — track each release

`transport: native` (BUG-018 territory) vs the pgwire default. Re-run the
sample app's `scripts/feature_smoke.rb` over both transports each NodeDB
release and update the `native` column. Target: full parity.

**v0.3.0** release (commit `25040fdf`), last run **2026-06-07**:

| Engine / area            | pgwire | native | Note |
| ------------------------ | ------ | ------ | ---- |
| Connection / `active?`   | PASS   | PASS   | `NativePGCompat` shim |
| Collections listing      | PASS   | PASS   | |
| Document CRUD (model)    | PASS   | PASS   | model path unpacks `data` |
| Timeseries               | PASS   | PASS   | |
| Graph (traverse/pagerank)| PASS   | PASS   | adapter-side `{nodes,edges}` passthrough still required |
| Spatial roundtrip        | PASS   | PASS   | result normaliser still required |
| FTS search / fuzzy       | PASS   | PASS   | upstream filter + flat projection still holding |
| KV                       | PASS   | FAIL   | native KV read shape mismatch (`KeyError "value"`) — unchanged from `2aaec0fd` |
| Vector search            | PASS   | ERR    | BUG-018 — blob, `distance` nil — unchanged from `2aaec0fd` |
| **Totals**               | **21/21** | **17/19** | |

## Adapter workarounds currently shipped

| Bug | Code path |
| --- | --------- |
| 002 | `nodedb_version` reads `SHOW server_version` |
| 003 | `database_version` / `get_database_version` return hardcoded `160000`; `check_version` is a no-op |
| 007 | `column_definitions` falls back to `DESCRIBE` and de-duplicates the result |
| 008 | `NodedbAdapter#exec_delete` re-issues DELETE outside any AR-opened transaction (still required through v0.3.0 — psql with `INT NOT NULL PK` persists, but AR's `document_strict` + text-PK `destroy` path still no-ops on both pgwire and native; verified by reverting the override and watching `adapter_spec` + `native_transport_spec` both fail) |
| ~~010, 013~~ | retired 2026-05-18 — `fts_search` issues `SELECT id … WHERE text_match()`; server filters; no bm25/unwrap |
| 014 | `NodedbAdapter#get_advisory_lock` / `#release_advisory_lock` no-op pair returning `true` (still needed — upstream returns empty, not boolean) |
| 016 | `Nodedb::SchemaMigration` / `Nodedb::InternalMetadata` declare PK on the built-in `id` column |
| 019 | `load_additional_types` no-op on every transport; `tables`, `primary_keys`, `pk_and_sequence_for`, `indexes`, `foreign_keys`, `check_constraints` use NodeDB-native paths on every transport (vquery refactor extends BUG-018-style gap to pgwire) |
| 020 | `NodeDB::Graph#graph_stats` issues the tenant-wide `SHOW GRAPH STATS` and filters the result set in Ruby by stripping JSON quotes from `row["collection"]` and matching the model's `table_name` |

## Workaround retirement strategy

- **004** workaround retired on v0.2.1: adapter now emits
  `DROP COLLECTION IF EXISTS` directly.
- **008** workaround **kept** through v0.3.0: the upstream fix is
  conditional on the column schema. v0.3.0 psql probe with
  `INT NOT NULL PRIMARY KEY` (numeric, strict-schema, not document_strict)
  persists DELETE inside txn, but AR's `record.destroy` against
  `document_strict` with a text PK still no-ops on both pgwire and
  native (confirmed 2026-06-07 by removing the override and watching
  both `adapter_spec` and `native_transport_spec` regress). Retest each
  future NodeDB release; retire when document_strict text-PK destroys
  inside txn.
- **009** had no adapter code workaround in the first place — the libpq
  noise filter only covered `INSERT EDGE` / `GRAPH ...`, never plain
  INSERT. Documented for completeness.
- **018** no workaround shipped — server-side fix is the correct layer
  (native should project document columns like pgwire). Re-run the
  transport-parity table each NodeDB release; a phase-2 adapter
  fallback (JSON-expand `data` on native) is the contingency if upstream
  declines parity.

- **010 / 013** workarounds **retired** on the 2026-05-18 upstream
  build: `text_match()` filters server-side and fuzzy mode returns a
  flat projection. `fts_search` simplified to
  `SELECT id … WHERE text_match()`; no bm25 projection / null-drop /
  JSON-unwrap. NodeDB also removed the standalone `fts` engine — FTS is
  a `document_strict` collection + `CREATE FULLTEXT INDEX`; the adapter
  ships `create_fts(name, fulltext: […])` and legacy `engine: :fts`
  maps to `document_strict`.

When NodeDB upstream fully resolves a bug, update the status above and
the per-bug doc, then ship the workaround removal as a separate PR
named `chore/remove-bugNNN-workaround`.
