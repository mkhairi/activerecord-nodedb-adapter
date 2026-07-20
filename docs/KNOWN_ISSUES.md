# Known issues

NodeDB-side quirks and limits, grouped by what they mean for adapter
users. Per-bug reproductions and workaround details live in the
[issue tracker](https://github.com/mkhairi/activerecord-nodedb-adapter/issues?q=%22%5Bupstream%3ANodeDB%5D%22)
(titles prefixed `[upstream:NodeDB] BUG-NNN` — each issue is the
canonical record; retests and workaround changes land there as
comments). This list tracks the **latest upstream
only** — resolved issues are pruned (git history and the CHANGELOG
keep the record).

Last retested: **2026-07-20** against upstream `main` at `eea86b279`
(v0.4.0 final). This head fixed the DROP USER dangling-owner boot
brick (BUG-035 — ownership is now reassigned and the startup check
repairs already-affected data directories) and the session plan
cache's stale-empty point lookups, and rejects duplicate
`CREATE TENANT` names. Still open from the previous wave:
BUG-045…049. New this round: BUG-050 — a two-statement graph repro
for the permanent metadata wedge.

## Adapter compensates transparently

You write idiomatic AR; the adapter swallows the workaround:

- **BUG-046 — regclass casts don't strip quoted identifiers.**
  `'"name"'::regclass` (the form Rails emits) silently resolves to
  NULL, so AR's stock reflection queries would see zero columns even
  though the catalog tables now exist. The adapter routes schema
  reflection through NodeDB-native paths (SHOW COLLECTIONS /
  DESCRIBE) and no-ops `load_additional_types`, so apps are
  unaffected.
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
  subclasses use `CREATE COLLECTION` + raw unqualified SQL (the
  metadata collection is keyed on NodeDB's mandatory `id` column);
  `rails db:migrate`, `db:schema:load`, and `db:prepare` work
  normally.
- **GRAPH TRAVERSE / INSERT EDGE quirks** — JSON-array row parsed and
  `IN 'collection'` threaded automatically by the `Graph` concern;
  harmless libpq stderr noise filtered by `Graph.silence_libpq_noise`.
- **`SEARCH ... USING VECTOR()` rejects quoted identifiers** — the
  `Vector` concern emits bare column names.

## Requires user awareness

- **BUG-045 — grouped-aggregate result cache is poisoned by select-list
  labeling** (`3eaa49873`): the first grouped-aggregate query on a
  collection in a session pins its labeling; running the same
  aggregate with different aliasing (aliased vs unaliased, either
  order) returns empty aggregate cells. AR's own grouped calculations
  alias deterministically and work; hand-written SQL, consoles, and
  mixed clients sharing pooled connections hit it. Keep one labeling
  per session, or reconnect.
- **BUG-047 — every `GRAPH INSERT EDGE` double-counts** (`eea86b279`):
  one insert registers 2 edges (and duplicate endpoint nodes) in
  `SHOW GRAPH STATS` and the per-label breakdown. No workaround —
  treat graph stats counters as unreliable; whether traversals also
  see duplicate edges is unconfirmed. See also BUG-050: the same
  doubled descriptor state appears to wedge the daemon on restart.
- **BUG-048 — native transport: committed INSERTs are invisible to PK
  point lookups and filtered aggregates** (`eea86b279`, native `:6433`
  only): a row committed inside `BEGIN…COMMIT` is durably stored
  (scans see it, survives reconnect) but `WHERE id = <pk>` returns 0
  rows, and a filtered `COUNT(*)` in the same session also misses it.
  AR wraps every `create!` in a transaction, so `find` breaks. pgwire
  is unaffected (v0.4.0's plan-cache fix resolved the analogous pgwire
  staleness) — keep `transport: native` off write paths (it remains
  secondary/on-hold pending the official SDK).
- **`SEARCH` cannot be wrapped in subqueries** (`IN (SEARCH ...)`,
  `FROM (SEARCH ...)` fail to parse). The `Vector` concern returns
  id + surrogate + distance; note the `id` column is only the document
  id on vector-engine collections (a result ordinal elsewhere), so do
  a follow-up `find` where you need the record.

## Open, no workaround

- **BUG-050 — `GRAPH INSERT EDGE` + daemon restart permanently wedges
  the metadata plane** (CRITICAL, `eea86b279`): a single edge insert
  leaves the collection's descriptor version inconsistent with the
  replicated metadata log; on the next restart the metadata applier
  hits a "descriptor version anomaly" for the graph-touched collection
  and retries forever. All DDL then times out daemon-wide, filtered
  `count(*)` hangs, DML on existing collections keeps working; only a
  data-directory rebuild recovers. 100% reproducible. Any app that
  touches the graph engine bricks its DDL plane at the next restart —
  avoid graph writes on data directories you intend to keep.
- **BUG-049 — drop-retention catalog instability escalating to a
  daemon-wide metadata wedge** (CRITICAL, `3eaa49873`): dropped
  collections resurrect; a collection recreated under a dropped name
  can flip back to "dropped, within retention window" minutes later
  (restore with `UNDROP COLLECTION`, then expect a ~30–60s
  "retryable schema change" settle); and the churn can corrupt the
  descriptor version chain, after which the metadata applier stalls
  permanently — every DDL statement times out
  (`metadata propose timed out … (current: N)`) daemon-wide, DML on
  existing collections keeps working, and only a data-directory
  rebuild recovers. Avoid DROP + CREATE of the same collection name
  on daemons you care about; verify recreated definitions again after
  several minutes.
- **BUG-051 — DROP TENANT deadlocks once the built-in tenant admin
  inherits ownership** (`eea86b279`): `DROP USER` reassigns owned
  objects (including drop-retention tombstones) to `<tenant>_admin`;
  `DROP TENANT` then refuses to drop that admin ("no active
  administrative principal available for ownership reassignment"),
  and the second-admin route is circular ("users still belong to
  it"). Any tenant in which a user ever owned a collection is
  permanently undroppable. Treat tenants as provision-only.
- **Spatial read-side accessors** — `ST_AsText` / `ST_X` / `ST_Y`
  return empty and `ST_DWithin` rejects constructor arguments, so
  spatial predicates remain unusable (write path works; raw GeoJSON
  column reads work). Last verified on `8e84501a`; not retested on
  `3eaa49873`.
- **`ROLLBACK AND CHAIN` unsupported** — surfaces when AR retries a
  failed nested transaction. A translation shim (`ROLLBACK; BEGIN`) is
  a possible future adapter addition. Last verified on `8e84501a`.
