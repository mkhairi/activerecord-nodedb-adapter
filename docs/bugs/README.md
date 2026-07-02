# NodeDB upstream bug log

Open NodeDB-side bugs the adapter has to dance around. Each entry has
a matching `<id>-<slug>.md` doc with reproduction, expected behaviour,
and adapter workaround.

This log tracks the **latest upstream only**. Resolved bugs are pruned
— their docs live in git history and the CHANGELOG records each
workaround retirement. Resolved and removed so far: 001, 002, 004,
005, 006, 009, 010, 011, 012, 013, 015, 016, 017, 020, 021, 022.

Last refreshed: **2026-07-02** against upstream `main` at `3a06321e`
(post-v0.3.0; `SHOW server_version` still reports `NodeDB 0.3.0`).
Note: that build changed the on-disk format vs pre-June builds (redb
graph `edges` table type) — old data dirs make the daemon panic on
boot; start fresh.

## Open bugs

| ID  | Title | Status |
| --- | ----- | ------ |
| 003 | `PQserverVersion()` raises `PG::ConnectionBad` | OPEN (retested `3a06321e`) — libpq parses the `server_version` ParameterStatus only, and `"NodeDB 0.3.0"` is non-numeric; the `server_version_num` param the upstream build advertises is ignored by libpq. Adapter derives the version via `current_setting` instead |
| 007 | `pg_attribute` query returns duplicate `id` row; `pg_attrdef` vtable missing | OPEN — adapter bypasses via `DESCRIBE` |
| 008 | Transactional DELETE leaves stale PK point-lookup phantom | RESHAPED on `3a06321e` — txn DELETE persists (scans clean, all PK forms), but `WHERE pk = ...` serves a phantom of the deleted row until the key is re-inserted. Reported upstream 2026-07-02. `exec_delete` workaround stays (autocommit re-issue avoids the phantom) |
| 014 | `pg_try_advisory_lock` / `pg_advisory_unlock` return zero rows (not boolean) | Upstream won't-fix on the pgwire surface; adapter no-op stubs are permanent until a native coordination primitive exists |
| 018 | Native protocol read shapes (document full-scan fragments, KV `value` missing, vector `distance` nil) | OPEN, symptom changed on `3a06321e` (per-core `result` JSON fragments). Native-transport work **on hold** — official SDK planned post-release; pgwire is the primary transport |
| 019 | vquery pg_catalog evaluator narrow shapes | OPEN, improved (`3a06321e`) — joins + `typelem` work, but `current_schemas()` returns an empty cell (breaks AR `tables`) and `pg_range`/`pg_attrdef` vtables are missing (breaks `load_additional_types` / `column_definitions`). All bypasses stay |
| 023 | MATCH `IN <collection>` ignores collection scope; plain DROP leaves edge-store entries visible to MATCH and `SHOW GRAPH STATS` | OPEN — discovered 2026-07-02 on `3a06321e`; MATCH exposure in the Graph concern on hold (#70) |
| 024 | Bitemporal collections lose INSERT and DELETE committed inside explicit transactions (UPDATE unaffected) | OPEN — discovered 2026-07-02 on `3a06321e`; AR cannot write bitemporal collections; `NodeDB::Bitemporal` read helpers parked on `feat/bitemporal-read-helpers` (#72) |
| 025 | Table-qualified column refs in WHERE silently match zero rows (except TEXT PK equality) | OPEN — discovered 2026-07-02 on `3a06321e`; adapter ships a dequalification rewrite in `perform_query` (#74) |
| 026 | User column named `bitemporal_id` on plain document_strict triggers BUG-024-style txn INSERT loss | OPEN — discovered 2026-07-02 on `3a06321e`; avoid the column name; blocks kufu-style app-level BTDM (#76) |
| 027 | `CREATE COLLECTION` engine spellings diverge: `WITH (engine=...)` + BITEMPORAL builds a broken schema; `ENGINE =` suffix silently ignores the timeseries engine | OPEN — discovered 2026-07-02 on `3a06321e`; nodedb-ruby builder picks the spelling per flag (#83) |

## Adapter workarounds currently shipped

| Bug | Code path |
| --- | --------- |
| 003 | `get_database_version` queries `current_setting('server_version_num')` (hardcoded `160000` fallback for older builds); `check_version` is a no-op |
| 007 | `column_definitions` falls back to `DESCRIBE` and de-duplicates the result |
| 008 | `NodedbAdapter#exec_delete` re-issues DELETE outside any AR-opened transaction (the autocommit path is clean on both scan and point-lookup reads) |
| 014 | `NodedbAdapter#get_advisory_lock` / `#release_advisory_lock` no-op pair returning `true` |
| 019 | `load_additional_types` no-op on every transport; `tables`, `primary_keys`, `pk_and_sequence_for`, `indexes`, `foreign_keys`, `check_constraints` use NodeDB-native paths on every transport |
| 025 | `NodedbAdapter#perform_query` strips the target-table qualifier from single-table SELECT/UPDATE/DELETE (JOIN/comma-FROM/aliased statements untouched); same rewrite on the BUG-008 `exec_delete` re-issue |
| — | Graph concern passes the bare `table_name` in `GRAPH INSERT EDGE IN` / `GRAPH ALGO ON`: the edge store keys collections by the IN-clause spelling verbatim, so a double-quoted identifier stores a literal-quoted key that scoped `SHOW GRAPH STATS` lookups miss (found retiring the BUG-020 fallback) |
| 027 | `nodedb-ruby SQL::Collection.create` emits `ENGINE = <engine>` for BITEMPORAL collections and `WITH (engine=...)` for everything else |

## Retirement policy

- **008** — retire `exec_delete` when a committed transactional DELETE
  stops serving PK point-lookup phantoms (retest each upstream build).
- **018** — no workaround by design; native transport is on hold
  pending the official client SDK.
- **025** — retire the dequalifier when qualified refs evaluate
  correctly upstream.
- When upstream fully resolves a bug: update this table and the
  per-bug doc, ship the workaround removal as a separate
  `chore/remove-bugNNN-workaround` PR, then prune the doc from this
  log (git history keeps it).
