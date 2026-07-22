# Known issues

NodeDB-side quirks and limits, grouped by what they mean for adapter
users. Per-bug reproductions and workaround details live in the
[issue tracker](https://github.com/mkhairi/activerecord-nodedb-adapter/issues?q=%22%5Bupstream%3ANodeDB%5D%22)
(titles prefixed `[upstream:NodeDB] BUG-NNN` — each issue is the
canonical record; retests and workaround changes land there as
comments). This list tracks the **latest upstream
only** — resolved issues are pruned (git history and the CHANGELOG
keep the record).

Last retested: **2026-07-22** against upstream `main` at `b04047b13`.
Everything open from the 0.4.0 era (BUG-045…052) plus BUG-053, BUG-054
and BUG-055 is fixed or no longer reproducible and has been pruned; the
native transport passes the full engine smoke at parity with pgwire.
Two upstream defects survive this retest unchanged (spatial read-side
accessors, `ROLLBACK AND CHAIN`) — both listed at the bottom.

One user-visible note survives BUG-055: over **HTTP**, a projection
whose output columns share a name emits `{"id": …, "id_1": …}`, because
a JSON object cannot repeat a key. pgwire and native are positional and
still report both columns as `id`, so the adapter is unaffected.

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
  Retested on `b04047b13`: `pg_advisory_lock` / `pg_try_advisory_lock`
  / `pg_advisory_unlock` now parse but return NULL and grant no mutual
  exclusion (a second session's `pg_try_advisory_lock` on a held key
  still succeeds), and `pg_locks` does not exist — the collection-based
  mutex stays.
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
- **`SEARCH ... USING VECTOR()` rejects a quoted collection name**
  (`SEARCH "articles" USING …` is a parse error; a quoted *column*
  is accepted as of `b04047b13`) — the `Vector` concern emits bare
  names either way.

## Requires user awareness

- **`SEARCH` cannot be wrapped in subqueries** — `FROM (SEARCH ...)`
  and `IN (SEARCH ...)` still fail to parse on `b04047b13`, so a hybrid
  query has to be two round trips. The `Vector` concern returns
  id + surrogate + distance; `id` is the document id (also on plain
  document collections carrying a vector index, retested on
  `b04047b13`), so a follow-up `find` gets you the record.

## Open, no workaround

- **Spatial read-side accessors** — `ST_AsText` / `ST_X` / `ST_Y`
  return empty and `ST_DWithin` rejects `ST_GeomFromText(...)`
  arguments ("invalid geometry … Invalid JSON value"), so spatial
  predicates remain unusable. The write path is healthy:
  `ST_GeomFromText` IS evaluated on INSERT and the stored GeoJSON
  reads back correctly as a raw column. Retested on `b04047b13`.
- **`ROLLBACK AND CHAIN` unsupported** ("unsupported: statement
  type: ROLLBACK AND CHAIN") — surfaces when AR retries a failed
  nested transaction. A translation shim (`ROLLBACK; BEGIN`) is a
  possible future adapter addition. Retested on `b04047b13`.
