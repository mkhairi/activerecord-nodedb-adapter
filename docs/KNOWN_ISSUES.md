# Known issues

NodeDB-side quirks and limits, grouped by what they mean for adapter
users. Per-bug reproductions and workaround details live in
[`docs/bugs/`](bugs/README.md). This list tracks the **latest upstream
only** — resolved issues are pruned (git history and the CHANGELOG
keep the record).

Last retested: **2026-07-04** against upstream `main` at `67c4572d`
(post-v0.3.0). That build reworked response shaping onto a
protocol-neutral core: the native transport is now at result-shape
parity with pgwire (BUG-018 resolved), but GROUP BY output regressed
(BUG-030) and pre-upgrade bitemporal collections stop versioning
(BUG-031).

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
- **BUG-030 — GROUP BY output drops group-key column aliases** (and
  reorders columns group-keys-first), which collapses every AR grouped
  calculation (`group(...).sum/count`) onto a `nil` key. The adapter
  renames the returned base column names back to the aliases the
  SELECT list requested. Unaliased aggregates in hand-written GROUP BY
  SQL still return empty cells — alias them.
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
- **BUG-014 — advisory locks missing** (upstream closed won't-fix on
  the pgwire surface, 2026-07-04). The adapter implements the
  migration mutex application-level: an `ar_advisory_locks`
  `document_strict` collection whose TEXT PRIMARY KEY makes
  acquisition an atomic INSERT. Cross-process `db:migrate` safety is
  restored (concurrent runs raise `ConcurrentMigrationError`), and a
  `with_advisory_lock(name, timeout_seconds:)` /
  `with_advisory_lock!` block API (modeled on the with_advisory_lock
  gem) is available for app-level coordination: guaranteed release
  via ensure, bounded waiting, thread-local reentrancy,
  `advisory_lock_exists?`, and `NODEDB_ADVISORY_LOCK_PREFIX`
  namespacing. Caveat: not session-scoped — a crashed holder's lock
  is stolen after `advisory_lock_ttl` seconds (config, default 3600).
- **Edge-store keys track the IN-clause spelling verbatim** — a
  double-quoted identifier in `GRAPH INSERT EDGE IN "name"` stores a
  literal-quoted key that scoped `SHOW GRAPH STATS` lookups miss. The
  Graph concern passes bare collection names for edge inserts and
  algo calls.
- **`schema_migrations` / `ar_internal_metadata`** — NodeDB-aware
  subclasses use `CREATE COLLECTION` + raw unqualified SQL; `rails
  db:migrate` works normally.
- **GRAPH TRAVERSE / INSERT EDGE quirks** — JSON-array row parsed and
  `IN 'collection'` threaded automatically by the `Graph` concern;
  harmless libpq stderr noise filtered by `Graph.silence_libpq_noise`.
- **`SEARCH ... USING VECTOR()` rejects quoted identifiers** — the
  `Vector` concern emits bare column names.

## Requires user awareness

- **`SEARCH` cannot be wrapped in subqueries** (`IN (SEARCH ...)`,
  `FROM (SEARCH ...)` fail to parse). The `Vector` concern returns
  id + surrogate + distance; note the `id` column is only the document
  id on vector-engine collections (a result ordinal elsewhere), so do
  a follow-up `find` where you need the record.
- **Do not name a column `bitemporal_id`** (BUG-026): on a plain
  `document_strict` collection that column name silently routes writes
  into bitemporal machinery — INSERTs committed inside transactions
  vanish. No adapter workaround; pick another name.
- **`count(*)` on an empty document collection returns zero rows**
  instead of a single `0` row.
- **`count(*)` never decrements after DELETE** (BUG-029): the first
  count materializes a row counter that INSERTs maintain but DELETEs
  don't, so counts drift upward permanently on previously-counted
  collections. Assert cardinality via scans around delete operations.
- **`transport: native` is at result-shape parity with pgwire** since
  BUG-018 was fixed upstream, but pgwire remains the primary,
  default transport — the hand-rolled native client will be replaced
  by NodeDB's official SDK once one ships.

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
- **BUG-031 — bitemporal versioned store freezes after a daemon
  upgrade**: collections created on an earlier build accept writes but
  never append post-upgrade versions to `AS OF SYSTEM TIME NULL`
  history. Recreate the collection on the new build (BUG-028 ghosts
  apply) or wipe the data dir. More broadly, `67c4572d` cannot decode
  rows written by `3a06321e` — pre-upgrade document rows project
  empty cells (`SELECT id, title` returns blanks while `count(*)`
  still sees them). Treat the upgrade as a data-directory format
  break: wipe and reseed.
- **BUG-032 — databases created by `CREATE DATABASE` are unusable**:
  DDL writes home to the new database, but DESCRIBE / SELECT /
  SHOW COLLECTIONS resolve against the default database only, so
  every collection created there is unreachable. Stick to the default
  database (the spec suite now does).
- **BUG-033 — a PK point-lookup miss poisons that key for the rest of
  the session** (`f8a4df44`): after `WHERE id = 'k'` returns nothing,
  a subsequent INSERT of `'k'` succeeds but the same bare PK-equality
  read keeps returning 0 rows (scans and compound predicates see the
  row; INSERT/UPDATE don't invalidate the cached miss). Breaks
  same-connection check-then-insert-then-read patterns like
  `find_or_create_by` + reload. No general adapter workaround — avoid
  re-reading a just-created key by bare PK equality on the same
  connection, or add any second predicate.
- **BUG-028 — DROP + CREATE of a bitemporal collection resurrects the
  old versioned-store history** (and a stale plain row) under the same
  name. Retested 2026-07-04, still present.
- **`ROLLBACK AND CHAIN` unsupported** — surfaces when AR retries a
  failed nested transaction. A translation shim (`ROLLBACK; BEGIN`) is
  a possible future adapter addition.
