# Known issues

NodeDB-side quirks and limits, grouped by what they mean for adapter
users. Per-bug reproductions, history, and workaround details live in
[`docs/bugs/`](bugs/README.md).

Last retested: **2026-07-02** against upstream `main` at `3a06321e`
(post-v0.3.0). Note: that build changed the on-disk format — daemons
booted on pre-June data directories panic at startup; start fresh.

## Resolved upstream

No adapter action needed on current builds:

- **BUG-001** `ResourcesExhausted` on non-timeseries INSERT (v0.2.0).
- **BUG-004** `DROP COLLECTION IF EXISTS` parser quirk (v0.2.1).
- **BUG-005** Prepared statements missing `RowDescription` — fixed;
  adapter still uses simple-query mode for safety.
- **BUG-006** Boolean column OID 0.
- **BUG-009** `INSERT` command tag missing OID slot (v0.2.1).
- **BUG-010 / BUG-013** FTS `text_match()` filtering and fuzzy JSON
  shape (2026-05-18 build); bm25/unwrap workarounds retired.
- **BUG-017** `SHOW server_version` stuck at 0.1.0 (v0.2.1).
- **BUG-002** `SELECT version()` empty — now returns a
  PostgreSQL-compatible banner; `current_setting('server_version_num')`
  returns a real value.
- **BUG-011 / BUG-012** Spatial INSERT: `ST_GeomFromText` /
  `ST_MakePoint` / `ST_GeomFromWKB` evaluate, geometry round-trips as
  GeoJSON, typed scalar columns persist. (Read-side accessors still
  broken — see below.)
- **BUG-015** DROP + CREATE resurrecting rows from the retention
  window — CREATE now hard-purges the soft-deleted incarnation.
- **BUG-016** `document_strict` empty-id collision with a non-`id`
  PK — doc id now derives from the declared PRIMARY KEY column.
- **BUG-020** `SHOW GRAPH STATS '<collection>'` all-zero counters —
  scoped form now correct (adapter Ruby-filter removal pending).
- **BUG-021** Bitemporal reads returning zero rows — plain SELECT,
  `count(*)` and `AS OF SYSTEM TIME` all project correctly now.
  (Bitemporal *transactional writes* are still broken — see BUG-024.)
- **BUG-022** Native-protocol SHOW routing — STATS/METRICS/MEMORY/ROLES
  return real row sets; adapter fail-soft retired.
- **`fts` engine removed upstream** — FTS is a `document_strict`
  collection + `CREATE FULLTEXT INDEX`. Use `create_fts(name,
  fulltext: [...])`; legacy `engine: :fts` maps to `document_strict`.

## Adapter compensates transparently

You write idiomatic AR; the adapter swallows the workaround:

- **BUG-025 — qualified WHERE refs silently match zero rows.** NodeDB
  matches nothing for `"table"."column"` predicates except TEXT-PK
  equality — which would break every AR hash-condition
  (`where(name: ...)`, conditional `count`, uniqueness validations).
  The adapter strips the target-table qualifier from single-table
  SELECT/UPDATE/DELETE before dispatch (JOINs and aliased FROMs are
  left untouched). This also fixes qualified projections
  (`SELECT "articles".*`).
- **BUG-008 — stale PK point-lookup after transactional DELETE.** The
  committed DELETE persists, but `WHERE pk = ...` keeps returning a
  phantom of the deleted row until the key is rewritten. The
  `exec_delete` override re-issues the DELETE outside the AR-opened
  transaction (the clean autocommit path), so `record.destroy` +
  `find` never sees the phantom. Reported upstream 2026-07-02.
- **BUG-003 — `PQserverVersion()` raises.** libpq can't parse the
  `server_version` ParameterStatus (`NodeDB 0.3.0`). The adapter asks
  the server via `current_setting('server_version_num')` (fallback
  constant for older builds) and no-ops `check_version`.
- **BUG-007 / BUG-019 — pg_catalog introspection gaps.**
  `current_schemas()` returns an empty cell and the `pg_range` /
  `pg_attrdef` vtables are missing, so AR's `tables`,
  `column_definitions`, and `load_additional_types` queries can't run
  as written. The adapter routes schema reflection through
  NodeDB-native paths (SHOW COLLECTIONS / DESCRIBE) and no-ops
  `load_additional_types`.
- **BUG-014 — advisory locks return empty rows** (upstream won't-fix
  on the pgwire surface). Adapter ships no-op
  `get_advisory_lock` / `release_advisory_lock` stubs so
  `db:migrate` works; cross-process migration mutex semantics are
  lost (acceptable single-instance alpha trade-off).
- **`schema_migrations` / `ar_internal_metadata`** — NodeDB-aware
  subclasses use `CREATE COLLECTION` + raw unqualified SQL; `rails
  db:migrate` works normally.
- **GRAPH TRAVERSE / INSERT EDGE quirks** — JSON-array row parsed and
  `IN 'collection'` threaded automatically by the `Graph` concern;
  harmless libpq stderr noise filtered by `Graph.silence_libpq_noise`.
- **`SEARCH ... USING VECTOR()` rejects quoted identifiers** — the
  `Vector` concern emits bare column names.

## Requires user awareness

- **`SELECT *` on schemaless document collections** returns
  `{"result" => "<json>"}` instead of flat columns. Project explicit
  columns or use `document_strict`.
- **`SEARCH` cannot be wrapped in subqueries** (`IN (SEARCH ...)`,
  `FROM (SEARCH ...)` fail to parse). The `Vector` concern returns
  surrogate + distance; do a follow-up `find`.
- **Do not name a column `bitemporal_id`** (BUG-026): on a plain
  `document_strict` collection that column name silently routes writes
  into bitemporal machinery — INSERTs committed inside transactions
  vanish. No adapter workaround; pick another name.
- **`count(*)` on an empty document collection returns zero rows**
  instead of a single `0` row.

## Open, no workaround

- **BUG-023 — `MATCH ... IN <collection>` ignores collection scope**;
  plain DROP leaves edge-store entries visible to MATCH and
  `SHOW GRAPH STATS`. MATCH exposure in the `Graph` concern is on
  hold until scoping works.
- **BUG-024 — bitemporal collections lose INSERT and DELETE committed
  inside explicit transactions** (UPDATE persists). ActiveRecord wraps
  every `create!`/`destroy` in a transaction, so bitemporal
  collections are effectively unwritable through AR. The
  `NodeDB::Bitemporal` read helpers are parked on an unmerged branch
  until this lands.
- **Spatial read-side accessors** — `ST_AsText` / `ST_X` / `ST_Y`
  return empty and `ST_DWithin` rejects constructor arguments, so
  spatial predicates remain unusable (write path works; raw GeoJSON
  column reads work).
- **BUG-018 — native transport shapes** (document full-scan fragments,
  KV `value` missing, vector `distance` nil). Native-transport work is
  **on hold** — the plan is to adopt the official NodeDB client SDK
  after an official release; pgwire remains the primary transport.
- **`ROLLBACK AND CHAIN` unsupported** — surfaces when AR retries a
  failed nested transaction. A translation shim (`ROLLBACK; BEGIN`) is
  a possible future adapter addition.
