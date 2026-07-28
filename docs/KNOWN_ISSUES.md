# Known issues

NodeDB-side quirks and limits, grouped by what they mean for adapter
users. Per-bug reproductions and workaround details live in the
[issue tracker](https://github.com/mkhairi/activerecord-nodedb-adapter/issues?q=%22%5Bupstream%3ANodeDB%5D%22)
(titles prefixed `[upstream:NodeDB] BUG-NNN` — each issue is the
canonical record; retests and workaround changes land there as
comments). This list tracks the **latest upstream
only** — resolved issues are pruned (git history and the CHANGELOG
keep the record).

Last retested: **2026-07-28** against upstream `main` at `87053aa7b`.
BUG-056 (spatial read-side accessors), BUG-059 (quoted collection name in
`SEARCH`), BUG-060 (advisory locks returning NULL) and BUG-061 (inert
`WITH (...)` vector index) are fixed and have been pruned. BUG-058 is
partially fixed — `SEARCH` composes as a derived table now, only the
`IN`-predicate shapes remain. Three new upstream defects landed with this
build: BUG-062 (first timeseries row loses its columns), BUG-063 (TIME_KEY
projection/type change) and BUG-064 (`current_database()` missing).

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
  Retested on `87053aa7b`: `pg_advisory_lock` / `pg_try_advisory_lock`
  / `pg_advisory_unlock` are back to failing loudly ("function … does
  not exist") and `pg_locks` does not exist — advisory locks remain
  unimplemented, so the collection-based mutex stays.
- **BUG-064 — `current_database()` missing** — AR's stock
  `SELECT current_database()` raises `PG::UndefinedFunction`, which
  aborts `rails db:migrate` before any migration runs. The adapter
  answers `current_database` from the connection's own dbname instead
  of asking the server. Remove once upstream implements the function.
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
- **BUG-063 — timeseries TIME_KEY column** — upstream no longer renames
  the `TIME_KEY` column to `timestamp` on read, and a column declared
  `TIMESTAMP TIME_KEY` returns epoch-ms integers under OID 1114.
  `create_collection(engine: :timeseries)` therefore declares
  `timestamp BIGINT TIME_KEY`, which keeps `NodeDB::Timeseries#since` /
  `#until_time` / `#time_bucket` working and keeps driver typecasting
  honest. Collections declaring a differently-named TIME_KEY need their
  own WHERE clauses.

## Requires user awareness

- **BUG-058 — `SEARCH` composes as a derived table but not in an
  `IN` predicate** — `FROM (SEARCH ...) s` works on `87053aa7b`
  (outer `WHERE` / `ORDER BY` / `LIMIT` included). `IN (SEARCH ...)`
  errors ("subquery projection must be a column reference"), and the
  `IN (SELECT id FROM (SEARCH ...) s)` spelling silently returns zero
  rows — do not use it. A hybrid query that needs an `IN` predicate is
  still two round trips. The `Vector` concern returns
  id + surrogate + distance; `id` is the document id, so a follow-up
  `find` gets you the record.

## Open, no workaround

- **BUG-062 — first timeseries row loses every non-TIME_KEY column** —
  on a timeseries collection created with an explicit column list (what
  `create_collection(engine: :timeseries)` emits), the first inserted
  row keeps only its TIME_KEY value; all other fields come back NULL.
  Later inserts are stored correctly and nothing reports the loss.
- **BUG-057 — `ROLLBACK AND CHAIN` unsupported** ("unsupported: statement
  type: ROLLBACK AND CHAIN") — surfaces when AR retries a failed
  nested transaction. A translation shim (`ROLLBACK; BEGIN`) is a
  possible future adapter addition. Retested on `87053aa7b`.
