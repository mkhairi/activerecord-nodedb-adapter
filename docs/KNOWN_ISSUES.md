# Known issues

NodeDB-side quirks and limits, grouped by what they mean for adapter
users. Per-bug reproductions and workaround details live in the
[issue tracker](https://github.com/mkhairi/activerecord-nodedb-adapter/issues?q=%22%5Bupstream%3ANodeDB%5D%22)
(titles prefixed `[upstream:NodeDB] BUG-NNN` — each issue is the
canonical record; retests and workaround changes land there as
comments). This list tracks the **latest upstream
only** — resolved issues are pruned (git history and the CHANGELOG
keep the record).

Last retested: **2026-07-07** against upstream `main` at `8e84501a`
(post-v0.3.0). A large fix wave resolved eight tracked bugs — graph
collection scoping (BUG-023), engine-spelling divergence (BUG-027),
bitemporal history resurrection (BUG-028), count-after-DELETE drift
(BUG-029), the bitemporal versioned-store freeze (BUG-031),
multi-database catalog reads (BUG-032), auth-churn flaps (BUG-034), and
the critical document restart-durability loss (BUG-036) — and the
qualified-WHERE (BUG-025) and GROUP-BY-alias (BUG-030) evaluator
defects, whose adapter workarounds are now removed. The same head
regressed scalar aggregates, filtered history reads, TIMESTAMP
upper-bound compares, timeseries restart replay, and DESCRIBE output
(BUG-037…041 below).

## Adapter compensates transparently

You write idiomatic AR; the adapter swallows the workaround:

- **BUG-007 / BUG-019 — pg_catalog introspection gaps.**
  `current_schemas()` returns an empty cell and the `pg_range` /
  `pg_attrdef` vtables are missing, so AR's `tables`,
  `column_definitions`, and `load_additional_types` queries can't run
  as written (regclass casts, cross-vtable joins, and `typelem` DO
  evaluate now). The adapter routes schema reflection through
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
- **BUG-041 — DESCRIBE lists the PK column twice** (`id TEXT` +
  `id TEXT PRIMARY KEY`, contradictory nullability) plus a `__storage`
  metadata row. Mostly masked because ActiveRecord keys columns by
  name and the schema dumper emits one entry, but code that iterates
  `connection.columns` sees the duplicate.
- **Unaliased aggregates in hand-written GROUP BY SQL return empty
  cells** (BUG-030's remaining case) — alias them
  (`SUM(x) AS sum_x`). AR's own grouped calculations always alias and
  work unmodified now.
- **`transport: native` is at result-shape parity with pgwire** since
  BUG-018 was fixed upstream, but pgwire remains the primary,
  default transport — the hand-rolled native client will be replaced
  by NodeDB's official SDK once one ships.

## Open, no workaround

- **BUG-037 — scalar aggregates return per-shard partial rows**
  (CRITICAL, `8e84501a`): `count(*)` / `SUM(...)` without GROUP BY
  return 11 rows (ten identity rows + the real value at a
  shard-dependent position), and an aliased scalar aggregate returns
  all-empty rows. `Model.count` / `.sum` therefore read `0`/`nil` most
  of the time, silently — pagination totals, `exists?`-style guards,
  and count assertions are all unreliable. Assert cardinality via
  scans (`Model.pluck(:id).size`) until fixed. Grouped calculations
  are unaffected.
- **BUG-038 — `AS OF SYSTEM TIME NULL` + `WHERE` returns zero rows**
  (`8e84501a`): the bare history scan works, so
  `Bitemporal.versions` is fine, but the per-record surface —
  `Bitemporal.history(pk)` and `.as_of(time)` with conditions —
  returns empty.
- **BUG-039 — TIMESTAMP upper-bound compares match zero rows**
  (`8e84501a`): `t <= ?`, `t < ?`, and `BETWEEN` on TIMESTAMP columns
  silently match nothing (`>=` / `>` work; INTEGER compares fine).
  Every date-window / expiry query shape is affected.
- **BUG-040 — timeseries collections lose AND duplicate points across
  daemon restarts** (`8e84501a`): the first restart after writes drops
  the newest point(s) and/or double-applies surviving ones on replay.
  Document/KV/graph/bitemporal data survive restarts intact (BUG-036
  is fixed); treat timeseries data as restart-volatile — reseed after
  daemon restarts.
- **BUG-035 — DROP USER leaves dangling catalog owner references that
  brick the next boot**: even with every owned collection dropped
  first, dropping a tenant user (and then its tenant) leaves an owner
  reference the boot integrity check refuses to repair — the data
  directory is unbootable without a wipe. Treat tenant users as
  provision-only.
- **Spatial read-side accessors** — `ST_AsText` / `ST_X` / `ST_Y`
  return empty and `ST_DWithin` rejects constructor arguments, so
  spatial predicates remain unusable (write path works; raw GeoJSON
  column reads work).
- **`ROLLBACK AND CHAIN` unsupported** — surfaces when AR retries a
  failed nested transaction. A translation shim (`ROLLBACK; BEGIN`) is
  a possible future adapter addition.
