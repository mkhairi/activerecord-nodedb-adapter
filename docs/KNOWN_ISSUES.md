# Known issues

NodeDB-side quirks and limits, grouped by what they mean for adapter
users. Per-bug reproductions and workaround details live in the
[issue tracker](https://github.com/mkhairi/activerecord-nodedb-adapter/issues?q=%22%5Bupstream%3ANodeDB%5D%22)
(titles prefixed `[upstream:NodeDB] BUG-NNN` — each issue is the
canonical record; retests and workaround changes land there as
comments). This list tracks the **latest upstream
only** — resolved issues are pruned (git history and the CHANGELOG
keep the record).

Last retested: **2026-07-21** against upstream `main` at `74febcf80`.
Cleanest wave so far: everything open from the 0.4.0 era —
BUG-045…051 and the sample app's ghost-tuple report (BUG-052) — is
fixed or no longer reproducible on a fresh data directory. The graph
restart wedge (BUG-050), the drop-retention instability (BUG-049), and
the DROP TENANT deadlock (BUG-051) are all gone; the native transport
passes the full engine smoke at parity with pgwire for the first time.
New this round: BUG-053, a mild stale-`count(*)` residue after
same-name collection recreates.

## Adapter compensates transparently

You write idiomatic AR; the adapter swallows the workaround:

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

- **BUG-054 — `LIMIT` on a virtual-catalog join returns 0 rows**
  (`74febcf80`): joining two pg_catalog tables (pg_type/pg_range,
  pg_attribute/pg_attrdef, …) with a `LIMIT` clause silently empties
  the result; the same query without LIMIT is correct, and real
  collections are unaffected. AR's stock reflection carries no LIMIT,
  so Rails apps are shielded; hand-written catalog queries should
  omit LIMIT and truncate client-side.
- **BUG-055 — qualified same-name columns in a join select list all
  resolve to the last table's value** (`74febcf80`): with two joined
  collections both carrying `id`, `SELECT w.id, b.id` returns the
  b-side value in BOTH columns; aliasing each projection
  (`w.id AS w_id, b.id AS b_id`) is correct. AR's eager_load aliases
  every column and plain `.joins` projects only the base table, so
  idiomatic AR is largely shielded — custom
  `select("a.id, b.id")`-style projections must alias.
- **BUG-053 — `count(*)` on a recreated same-name collection reports
  the dropped predecessor's row count until the first write**
  (`74febcf80`): after `DROP COLLECTION x` + `CREATE COLLECTION x`,
  the new empty collection's `count(*)` returns the old collection's
  count (full scans are correct, and the stale value heals on the
  first INSERT). Emptiness checks (`Model.count`, count-based
  `exists?` patterns) lie right after a same-name rebuild — e.g.
  `db:schema:load`-style flows. Use a scan-based check if it matters.
- **`SEARCH` cannot be wrapped in subqueries** (`IN (SEARCH ...)`,
  `FROM (SEARCH ...)` fail to parse). The `Vector` concern returns
  id + surrogate + distance; note the `id` column is only the document
  id on vector-engine collections (a result ordinal elsewhere), so do
  a follow-up `find` where you need the record.

## Open, no workaround

- **Spatial read-side accessors** — `ST_AsText` / `ST_X` / `ST_Y`
  return empty and `ST_DWithin` rejects `ST_GeomFromText(...)`
  arguments ("invalid geometry … Invalid JSON value"), so spatial
  predicates remain unusable. The write path is healthy:
  `ST_GeomFromText` IS evaluated on INSERT and the stored GeoJSON
  reads back correctly as a raw column. Retested on `74febcf80`.
- **`ROLLBACK AND CHAIN` unsupported** ("unsupported: statement
  type") — surfaces when AR retries a failed nested transaction. A
  translation shim (`ROLLBACK; BEGIN`) is a possible future adapter
  addition. Retested on `74febcf80`.
