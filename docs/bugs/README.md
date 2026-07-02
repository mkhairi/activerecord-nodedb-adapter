# NodeDB upstream bug log

NodeDB-side bugs the adapter has had to dance around. Each entry has a
matching `<id>-<slug>.md` doc with reproduction, expected behaviour, and
adapter workaround.

Last refreshed: **2026-07-02** against upstream `main` at `3a06321e`
(post-v0.3.0, ~295 commits past `25040fdf`; `SHOW server_version` still
reports `NodeDB 0.3.0`). This build fixed eight tracked bugs in one
sweep (002, 011, 012, 015, 016, 020, 021, 022 — see below). Note: the
on-disk format changed vs pre-June builds (redb graph `edges` table
type) — old data dirs make the daemon panic on boot; start fresh.

| ID  | Title | Status |
| --- | ----- | ------ |
| 001 | INSERT returns `ResourcesExhausted` on non-timeseries engines | RESOLVED — fixed in nodedb v0.2.0 (`EngineConfig` covers all 15 engines) |
| 002 | `SELECT version()` returns empty | **RESOLVED** upstream (`3a06321e`, NodeDB-Lab/nodedb#142) — `version()`, `current_setting('server_version_num')` and `('server_version')` all real; BUG-003 (`PQserverVersion`) still open |
| 003 | `PQserverVersion()` raises `PG::ConnectionBad` | OPEN (retested `3a06321e`) — libpq parses the `server_version` ParameterStatus only, and `"NodeDB 0.3.0"` is non-numeric; the `server_version_num` param the upstream build now advertises is ignored by libpq. Adapter hardcodes `160000` |
| 004 | `DROP COLLECTION IF EXISTS` parses `IF` as a name when collection exists | **RESOLVED** in v0.2.1 — adapter now emits `DROP COLLECTION IF EXISTS` directly (workaround retired) |
| 005 | Prepared statements missing `RowDescription` before `DataRow` | RESOLVED |
| 006 | Unknown OID `0` for boolean column | RESOLVED |
| 007 | `pg_attribute` query returns duplicate `id` row | RESHAPED by [BUG-019](019-vquery-pg-catalog-narrow-shapes.md) — vquery refactor changes pg_attribute behaviour; adapter still bypasses via `DESCRIBE` |
| 008 | DELETE inside transaction silently dropped | **RESHAPED** on `3a06321e` — txn DELETE now persists (scans clean, all PK forms), but the PK point-lookup serves a phantom of the deleted row until the key is re-inserted. Filed upstream as NodeDB-Lab/nodedb#148. `exec_delete` workaround stays (autocommit re-issue avoids the phantom) |
| 009 | INSERT command tag missing OID slot | **RESOLVED** in v0.2.1 — `INSERT 0 N` form now emitted |
| 010 | `text_match()` predicate doesn't filter rows | **RESOLVED** upstream (2026-05-18 build) — filters server-side; adapter bm25 workaround retired |
| 011 | Spatial INSERT does not evaluate `ST_GeomFromText` | **RESOLVED** upstream (`3a06321e`, NodeDB-Lab/nodedb#141) — constructors evaluate, GeoJSON round-trips; read-side `ST_AsText`/`ST_X`/`ST_DWithin` still broken (separate issue) |
| 012 | Spatial engine drops non-geometry typed columns on INSERT | **RESOLVED** upstream (`3a06321e`) — typed scalars round-trip on `engine=spatial` |
| 013 | FTS fuzzy mode returns wrapped JSON | **RESOLVED** upstream (2026-05-18 build) — flat projection in fuzzy mode; adapter unwrap retired |
| 014 | `pg_try_advisory_lock` / `pg_advisory_unlock` missing | PARTIAL through v0.3.0 — parsed, still return zero rows (not boolean); adapter stubs still required |
| 015 | DROP + CREATE resurrects old rows in retention window | **RESOLVED** upstream (`3a06321e`, NodeDB-Lab/nodedb#139) — CREATE over a soft-deleted name hard-purges first |
| 016 | `document_strict` 2nd INSERT collides on empty `id` when PK on non-`id` column | **RESOLVED** upstream (`3a06321e`, NodeDB-Lab/nodedb#138) — doc id derived from declared PK; adapter id-column mapping (PR #24) kept as harmless convention |
| 017 | `SHOW server_version` stuck at "NodeDB 0.1.0" | **RESOLVED** in v0.2.1 (upstream PR #114) |
| 018 | Native protocol returns document-backed rows as a raw `{data,id}` blob (no virtual-column projection); pgwire unaffected | OPEN — `transport: native` only; no adapter workaround yet |
| 019 | vquery pg_catalog evaluator narrow shapes | OPEN, improved (`3a06321e`) — joins + `typelem` now work, but `current_schemas()` returns an empty cell (breaks AR `tables`) and `pg_range`/`pg_attrdef` vtables are missing (breaks `load_additional_types` / `column_definitions`). All bypasses stay |
| 020 | `SHOW GRAPH STATS '<collection>'` returns all-zero counters even when the tenant-wide form proves the collection has edges | **RESOLVED** upstream (`3a06321e`, NodeDB-Lab/nodedb#134) — scoped form matches tenant-wide, names bare in both; Ruby-filter removal pending (`chore/remove-bug020-workaround`) |
| 021 | Reads against a `BITEMPORAL` collection return zero rows even when prior INSERTs reported success | **RESOLVED** upstream (`3a06321e`, NodeDB-Lab/nodedb#135) — plain SELECT / count(*) / `AS OF SYSTEM TIME` all project correctly; no adapter workaround ever shipped |
| 022 | Native protocol routes `SHOW <command>` (STATS / METRICS / MEMORY / ROLES) through the session-parameter handler instead of the DDL router | **RESOLVED** upstream (`3a06321e`, NodeDB-Lab/nodedb#136) — native SHOW returns real row sets; adapter fail-soft removed in `chore/remove-bug022-workaround` |
| 023 | MATCH `IN <collection>` ignores collection scope; plain DROP leaves edge-store entries visible to MATCH and `SHOW GRAPH STATS` | OPEN — discovered 2026-07-02 on `3a06321e`; MATCH exposure in the Graph concern on hold (#70) |
| 024 | Bitemporal collections lose INSERT and DELETE committed inside explicit transactions (UPDATE unaffected) | OPEN — discovered 2026-07-02 on `3a06321e`; AR cannot write bitemporal collections; `NodeDB::Bitemporal` read helpers parked on `feat/bitemporal-read-helpers` (#72) |
| 025 | Table-qualified column refs in WHERE silently match zero rows (except TEXT PK equality) — breaks every AR hash-condition on non-PK columns | OPEN — discovered 2026-07-02 on `3a06321e`; adapter ships a dequalification rewrite in `perform_query` (`fix/dequalify-single-table-where`), #74 |
| 026 | User column named `bitemporal_id` on plain document_strict triggers BUG-024-style txn INSERT loss | OPEN — discovered 2026-07-02 on `3a06321e`; avoid the column name; blocks kufu-style app-level BTDM (#76) |

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
| 003 | `get_database_version` queries `current_setting('server_version_num')` (hardcoded `160000` fallback for older builds); `check_version` is a no-op |
| 007 | `column_definitions` falls back to `DESCRIBE` and de-duplicates the result |
| 008 | `NodedbAdapter#exec_delete` re-issues DELETE outside any AR-opened transaction (still required through v0.3.0 — psql with `INT NOT NULL PK` persists, but AR's `document_strict` + text-PK `destroy` path still no-ops on both pgwire and native; verified by reverting the override and watching `adapter_spec` + `native_transport_spec` both fail) |
| ~~010, 013~~ | retired 2026-05-18 — `fts_search` issues `SELECT id … WHERE text_match()`; server filters; no bm25/unwrap |
| 014 | `NodedbAdapter#get_advisory_lock` / `#release_advisory_lock` no-op pair returning `true` (still needed — upstream returns empty, not boolean) |
| 016 | `Nodedb::SchemaMigration` / `Nodedb::InternalMetadata` declare PK on the built-in `id` column |
| 019 | `load_additional_types` no-op on every transport; `tables`, `primary_keys`, `pk_and_sequence_for`, `indexes`, `foreign_keys`, `check_constraints` use NodeDB-native paths on every transport (vquery refactor extends BUG-018-style gap to pgwire) |
| 020 | `NodeDB::Graph#graph_stats` issues the tenant-wide `SHOW GRAPH STATS` and filters the result set in Ruby (upstream fixed on `3a06321e`; removal pending as `chore/remove-bug020-workaround`) |
| 025 | `NodedbAdapter#perform_query` strips the target-table qualifier from single-table SELECT/UPDATE/DELETE (JOIN/comma-FROM/aliased statements untouched); same rewrite on the BUG-008 `exec_delete` re-issue |
| ~~022~~ | retired 2026-07-02 — native SHOW routes through the DDL router upstream; `show_command` forwards rows as-is |

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

- **022** workaround **retired** 2026-07-02 (upstream `3a06321e`,
  NodeDB-Lab/nodedb#136): `show_command` no longer detects the native
  placeholder shape; `native_show_placeholder?` deleted. The
  native-transport specs assert real row sets for
  `show_stats` / `show_metrics` / `show_memory` and a non-placeholder
  shape for `show_roles`.
- **016 / 020** upstream-fixed on `3a06321e` but their adapter code
  still ships: the `SchemaMigration`/`InternalMetadata` id-column
  mapping (016) is a harmless convention and stays; the
  `NodeDB::Graph#graph_stats` Ruby filter (020) is pending removal as
  `chore/remove-bug020-workaround`.
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
