# NodeDB upstream bug log

Open NodeDB-side bugs the adapter has to dance around. Each entry has
a matching `<id>-<slug>.md` doc with reproduction, expected behaviour,
and adapter workaround.

This log tracks the **latest upstream only**. Resolved bugs are pruned
— their docs live in git history and the CHANGELOG records each
workaround retirement. Resolved and removed so far: 001, 002, 004,
005, 006, 008, 009, 010, 011, 012, 013, 015, 016, 017, 018, 020, 021,
022, 024, 026.

Last refreshed: **2026-07-04** against upstream `main` at `f8a4df44`
(post-v0.3.0; `SHOW server_version` reports `NodeDB 0.3.0`). That
head's transactional DELETE/PUT rework resolved BUG-008 (txn DELETE
phantom), BUG-024 (bitemporal txn INSERT/DELETE loss — AR can write
bitemporal collections now), and BUG-026 (`bitemporal_id` column
name) — but introduced BUG-033 (negative point-lookup cache
poisoning). Earlier the same day, `67c4572d`'s response-shaping rework
resolved BUG-018 (native at result-shape parity with pgwire) while
regressing GROUP BY output (BUG-030) and multi-database catalog reads
(BUG-032).

## Open bugs

| ID  | Title | Status |
| --- | ----- | ------ |
| 003 | `PQserverVersion()` raises `PG::ConnectionBad` | OPEN (retested `f8a4df44` after the upstream version-reporting hotfix) — libpq parses the `server_version` ParameterStatus only, and `"NodeDB 0.3.0"` is non-numeric; the advertised `server_version_num` param is ignored by libpq. Adapter derives the version via `current_setting` instead; needs `server_version` itself to lead with digits |
| 007 | `pg_attribute` query returns duplicate `id` row; `pg_attrdef` vtable missing | OPEN — adapter bypasses via `DESCRIBE` |
| 014 | `pg_try_advisory_lock` / `pg_advisory_unlock` missing | CLOSED upstream won't-fix (2026-07-04) — adapter implements the migration mutex application-level via the `ar_advisory_locks` collection (atomic PK INSERT, owner-checked release, TTL stale steal) |
| 019 | vquery pg_catalog evaluator narrow shapes | OPEN, improved (`3a06321e`) — joins + `typelem` work, but `current_schemas()` returns an empty cell (breaks AR `tables`) and `pg_range`/`pg_attrdef` vtables are missing (breaks `load_additional_types` / `column_definitions`). All bypasses stay |
| 023 | MATCH `IN <collection>` ignores collection scope; plain DROP leaves edge-store entries visible to MATCH and `SHOW GRAPH STATS` | OPEN — discovered 2026-07-02 on `3a06321e`; MATCH exposure in the Graph concern on hold (#70) |
| 025 | Table-qualified column refs in WHERE silently match zero rows (except TEXT PK equality) | OPEN — discovered 2026-07-02 on `3a06321e`; adapter ships a dequalification rewrite in `perform_query` (#74) |
| 027 | `CREATE COLLECTION` engine spellings diverge: `WITH (engine=...)` + BITEMPORAL builds a broken schema; `ENGINE =` suffix silently ignores the timeseries engine | OPEN — discovered 2026-07-02 on `3a06321e`; nodedb-ruby builder picks the spelling per flag (#83) |
| 028 | DROP + CREATE of a BITEMPORAL collection resurrects the old versioned-store history (name poisoned until data-dir wipe) | OPEN — discovered 2026-07-02 on `3a06321e`; no client-side workaround (#85) |
| 029 | `count(*)` materializes a row counter that DELETE never decrements — counts drift upward permanently on previously-counted collections | OPEN — isolated 2026-07-03 on `3a06321e`; assert cardinality via scans around deletes (#90) |
| 030 | GROUP BY output drops group-key column aliases, reorders columns group-keys-first; unaliased aggregates return empty cells | OPEN — regression discovered 2026-07-04 on `67c4572d`; adapter re-aliases GROUP BY result columns in `perform_query` |
| 031 | Bitemporal versioned store stops recording after a daemon upgrade (pre-upgrade collections accept writes but append no history) | OPEN — discovered 2026-07-04 on `67c4572d`; no client-side workaround; recreate the collection (BUG-028 ghosts apply) or wipe the data dir |
| 032 | Databases created by `CREATE DATABASE` are unusable — DDL writes home to the new database but catalog reads (DESCRIBE / SELECT / SHOW COLLECTIONS) resolve against the default database only | OPEN — regression discovered 2026-07-04 on `67c4572d`; retested still open on `f8a4df44`; spec suite targets the default database until multi-database works again |
| 033 | A PK point-lookup miss poisons that key's bare `WHERE id =` reads for the rest of the session — INSERT/UPDATE don't invalidate the cached miss (scans and compound predicates see the row) | OPEN — regression discovered 2026-07-04 on `f8a4df44`; advisory-lock machinery reads via scan; no general workaround for model reads |
| 034 | Transient `Password authentication failed` under rapid connection churn — correct credentials rejected for ~1s bursts, nothing logged; long-lived pooled connections unaffected | OPEN — observed 2026-07-04 on `67c4572d` and `f8a4df44`; retry the connection after ~1s |

## Adapter workarounds currently shipped

| Bug | Code path |
| --- | --------- |
| 003 | `get_database_version` queries `current_setting('server_version_num')` (hardcoded `160000` fallback for older builds); `check_version` is a no-op |
| 007 | `column_definitions` falls back to `DESCRIBE` and de-duplicates the result |
| 014 | `Nodedb::AdvisoryLocks` — collection-based mutex (`ar_advisory_locks`): atomic PK INSERT to acquire, owner-checked DELETE to release, stale rows stolen after `advisory_lock_ttl` (default 3600s). Migrator contract plus `with_advisory_lock`/`with_advisory_lock!` block API (ensure-release, `timeout_seconds` polling, thread-local reentrancy, `advisory_lock_exists?`, `NODEDB_ADVISORY_LOCK_PREFIX` namespacing) |
| 033 | `AdvisoryLocks#advisory_lock_row` scans the lock collection and filters client-side instead of `WHERE id =` (the lock flow reads a key right before inserting it — exactly the poisoned shape) |
| 019 | `load_additional_types` no-op on every transport; `tables`, `primary_keys`, `pk_and_sequence_for`, `indexes`, `foreign_keys`, `check_constraints` use NodeDB-native paths on every transport |
| 025 | `NodedbAdapter#perform_query` strips the target-table qualifier from single-table SELECT/UPDATE/DELETE (JOIN/comma-FROM/aliased statements untouched) |
| 030 | `NodedbAdapter#realias_group_by_columns` renames GROUP BY result columns back to the aliases the SELECT list requested (thin delegator over the raw result) |
| — | Graph concern passes the bare `table_name` in `GRAPH INSERT EDGE IN` / `GRAPH ALGO ON`: the edge store keys collections by the IN-clause spelling verbatim, so a double-quoted identifier stores a literal-quoted key that scoped `SHOW GRAPH STATS` lookups miss (found retiring the BUG-020 fallback) |
| 027 | `nodedb-ruby SQL::Collection.create` emits `ENGINE = <engine>` for BITEMPORAL collections and `WITH (engine=...)` for everything else |

## Retirement policy

- **025** — retire the dequalifier when qualified refs evaluate
  correctly upstream.
- **030** — retire `realias_group_by_columns` when GROUP BY output
  honours column aliases upstream.
- When upstream fully resolves a bug: update this table and the
  per-bug doc, ship the workaround removal as a separate
  `chore/remove-bugNNN-workaround` PR, then prune the doc from this
  log (git history keeps it).
