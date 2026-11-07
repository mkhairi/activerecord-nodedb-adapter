# Known issues

NodeDB-side quirks and limits, grouped by what they mean for adapter
users. Per-bug reproductions and workaround details live in the
[issue tracker](https://github.com/mkhairi/activerecord-nodedb-adapter/issues?q=%22%5Bupstream%3ANodeDB%5D%22)
(titles prefixed `[upstream:NodeDB] BUG-NNN` — each issue is the
canonical record; retests and workaround changes land there as
comments). This list tracks the **latest upstream
only** — resolved issues are pruned (git history and the CHANGELOG
keep the record).

Last retested: **2026-11-07** against upstream `main` at `4b7784861`
(nodedb 0.7.0-dev). Everything tracked before this build is fixed and
pruned except the entries below.

One user-visible note: over **HTTP**, a projection whose output columns
share a name emits `{"id": …, "id_1": …}`, because a JSON object cannot
repeat a key. pgwire and native are positional and still report both
columns as `id`, so the adapter is unaffected.

## Adapter compensates transparently

You write idiomatic AR; the adapter swallows the workaround:

- **Advisory locks are unimplemented** (upstream won't-fix on the
  pgwire surface: the `pg_advisory_*` family raises "function does not
  exist" and `pg_locks` is absent). The adapter implements the
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
- **BUG-064 — `current_database()` missing** — AR's stock
  `SELECT current_database()` raises `PG::UndefinedFunction`, which
  aborts `rails db:migrate` before any migration runs. The adapter
  answers `current_database` from the connection's own dbname instead
  of asking the server. Remove once upstream implements the function.
- **BUG-069 — qualified columns in `IN`, `NOT IN`, `BETWEEN`, `LIKE`
  match zero rows** — AR qualifies every hash condition, so the adapter
  strips a single-table statement's own qualifier before dispatch.
  `where(id: [...])`, `find([...])`, `where(n: 1..5)` and `update_all` work
  through AR. Hand-written qualified SQL sent past the adapter, and a
  subquery on another table inside a statement, stay exposed.
- **BUG-070 — free-standing `BITEMPORAL` and `APPEND_ONLY` are ignored** —
  `create_collection(bitemporal: true)` emits `WITH (bitemporal=true)`,
  which takes effect. Collections created by an earlier adapter version
  are not bitemporal and keep 300 seconds of history. Recreate them.
- **BUG-072 — `UPDATE` fails on a `(key, value)` KV collection** — `kv_set`
  writes through `INSERT ... ON CONFLICT`.
- **BUG-073 — three text renderings of a vector** — the `Vector` type
  casts all three.
- **Delete tombstones in bitemporal history** — NodeDB records a delete as
  a version that repeats the old values. `versions` and `history` hide it.
  Pass `include_tombstones: true` to see it.
- **`schema_migrations` / `ar_internal_metadata`** — NodeDB-aware
  subclasses use `CREATE COLLECTION` + raw unqualified SQL (the
  metadata collection is keyed on NodeDB's mandatory `id` column);
  `rails db:migrate`, `db:schema:load`, and `db:prepare` work
  normally.
- **GRAPH TRAVERSE / INSERT EDGE quirks** — JSON-array row parsed and
  `IN 'collection'` threaded automatically by the `Graph` concern;
  harmless libpq stderr noise filtered by `Graph.silence_libpq_noise`.

## Requires user awareness

- **Timeseries columns must be declared** —
  `create_collection(engine: :timeseries)` declares only `timestamp` and
  `value`, and NodeDB rejects any other column with `42703`. Use
  `create_timeseries` with a block to declare the fields you write. The
  helpers assume the `TIME_KEY` column is named `timestamp`.
- **`DELETE` on a timeseries collection raises an error** — expire rows with
  `CREATE RETENTION POLICY`, or clear them with `TRUNCATE`.
- **Native transport decode gaps** — a timestamp arrives as
  `[<microseconds>]` and a geometry as its SRID (`4326`), with no
  coordinates. pgwire returns a `Time` and GeoJSON. Native decoding is on
  hold until an official client ships.

## Open, no workaround

- **BUG-071 — a column named `version`, `user`, `current_date` or
  `current_schema` resolves to the function** — `SELECT version` returns the
  server version string, `WHERE version = 7` matches nothing, and
  `SET version = version + 1` silently writes NULL. The others raise
  "function does not exist" on read. Rename the column. `SELECT *` returns
  the stored value. `schema_migrations` stays keyed on `id` for this reason.
- **BUG-072, AR updates and TTL** — `record.update(value: ...)` on a model
  over a `(key, value)` KV collection fails with "key holds a bare value",
  and so does the `ttl:` option of `kv_set`.
- **BUG-057 — `ROLLBACK AND CHAIN` unsupported** ("unsupported: statement
  type: ROLLBACK AND CHAIN") — surfaces when AR retries a failed nested
  transaction. A translation shim (`ROLLBACK; BEGIN`) is a possible future
  adapter addition. Retested on `4b7784861`.
