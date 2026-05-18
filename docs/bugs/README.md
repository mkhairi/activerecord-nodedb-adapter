# NodeDB upstream bug log

NodeDB-side bugs the adapter has had to dance around. Each entry has a
matching `<id>-<slug>.md` doc with reproduction, expected behaviour, and
adapter workaround.

Last refreshed: **2026-05-18** against a post-**v0.2.1** upstream build
(commit `a178aa5b`; reports `0.2.1`).

| ID  | Title | Status |
| --- | ----- | ------ |
| 001 | INSERT returns `ResourcesExhausted` on non-timeseries engines | RESOLVED — fixed in nodedb v0.2.0 (`EngineConfig` covers all 15 engines) |
| 002 | `SELECT version()` returns empty | OPEN — adapter uses `SHOW server_version` |
| 003 | `PQserverVersion()` raises `PG::ConnectionBad` | OPEN — adapter hardcodes `160000` |
| 004 | `DROP COLLECTION IF EXISTS` parses `IF` as a name when collection exists | **RESOLVED** in v0.2.1 — adapter now emits `DROP COLLECTION IF EXISTS` directly (workaround retired) |
| 005 | Prepared statements missing `RowDescription` before `DataRow` | RESOLVED |
| 006 | Unknown OID `0` for boolean column | RESOLVED |
| 007 | `pg_attribute` query returns duplicate `id` row | PARTIAL — adapter falls back to `DESCRIBE` |
| 008 | DELETE inside transaction silently dropped | **PARTIAL** in v0.2.1 — fixed only when PK column lacks explicit `NOT NULL`; AR DDL still hits the broken path; `exec_delete` workaround still required |
| 009 | INSERT command tag missing OID slot | **RESOLVED** in v0.2.1 — `INSERT 0 N` form now emitted |
| 010 | `text_match()` predicate doesn't filter rows | OPEN — adapter filters by `bm25_score` (PR #15) |
| 011 | Spatial INSERT does not evaluate `ST_GeomFromText` | CHANGED — now hard error (was silent text store); spatial engine still unusable |
| 012 | Spatial engine drops non-geometry typed columns on INSERT | OBSCURED by 011 (cannot INSERT to test) |
| 013 | FTS fuzzy mode returns wrapped JSON | OPEN — adapter unwraps in `fts_search` (PR #17) |
| 014 | `pg_try_advisory_lock` / `pg_advisory_unlock` missing | PARTIAL in v0.2.1 — parsed now, return empty (silent no-op); adapter stubs still required |
| 015 | DROP + CREATE resurrects old rows in retention window | OPEN — sample app reconciles in `bin/setup` |
| 016 | `document_strict` 2nd INSERT collides on empty `id` when PK on non-`id` column | OPEN — adapter stores user keys in built-in `id` column (PR #24) |
| 017 | `SHOW server_version` stuck at "NodeDB 0.1.0" | **RESOLVED** in v0.2.1 (upstream PR #114) |
| 018 | Native protocol returns document-backed rows as a raw `{data,id}` blob (no virtual-column projection); pgwire unaffected | OPEN — `transport: native` only; no adapter workaround yet |

## Transport parity (pgwire vs native) — track each release

`transport: native` (BUG-018 territory) vs the pgwire default. Re-run the
sample app's `scripts/feature_smoke.rb` over both transports each NodeDB
release and update the `native` column. Target: full parity.

Post-**v0.2.1** build (commit `a178aa5b`), last run **2026-05-18**:

| Engine / area            | pgwire | native | Note |
| ------------------------ | ------ | ------ | ---- |
| Connection / `active?`   | PASS   | PASS   | `NativePGCompat` shim |
| Collections listing      | PASS   | PASS   | |
| Document CRUD (model)    | PASS   | PASS   | model path unpacks `data` |
| Timeseries               | PASS   | PASS   | |
| Graph (traverse/pagerank)| PASS   | PASS   | regressed on this build, **fixed adapter-side** (graph `{nodes,edges}` passthrough) |
| Spatial roundtrip        | PASS   | PASS   | fixed by result normaliser |
| FTS search / fuzzy       | PASS   | PASS   | **fixed upstream** on this build (native now projects `bm25_score`) |
| KV                       | PASS   | FAIL   | native KV read shape mismatch (`KeyError "value"`) |
| Vector search            | PASS   | ERR    | BUG-018 — blob, `distance` nil |
| **Totals**               | **21/21** | **17/19** | |

## Adapter workarounds currently shipped

| Bug | Code path |
| --- | --------- |
| 002 | `nodedb_version` reads `SHOW server_version` |
| 003 | `database_version` / `get_database_version` return hardcoded `160000`; `check_version` is a no-op |
| 007 | `column_definitions` falls back to `DESCRIBE` and de-duplicates the result |
| 008 | `NodedbAdapter#exec_delete` re-issues DELETE outside any AR-opened transaction (still required on v0.2.1 — fix is conditional, AR's `NOT NULL PRIMARY KEY` DDL hits the broken path) |
| 010, 013 | `NodeDB::FullTextSearch#fts_search` projects `id, bm25_score`, filters nulls, JSON-unwraps fuzzy rows |
| 014 | `NodedbAdapter#get_advisory_lock` / `#release_advisory_lock` no-op pair returning `true` (still needed — upstream returns empty, not boolean) |
| 016 | `Nodedb::SchemaMigration` / `Nodedb::InternalMetadata` declare PK on the built-in `id` column |

## Workaround retirement strategy

- **004** workaround retired on v0.2.1: adapter now emits
  `DROP COLLECTION IF EXISTS` directly.
- **008** workaround **kept** on v0.2.1: the upstream fix is conditional
  on the column schema (works for implicit `NOT NULL`, broken for the
  explicit `NOT NULL PRIMARY KEY` AR emits). Retest each future NodeDB
  release; retire when AR's emitted DDL persists DELETE inside txn.
- **009** had no adapter code workaround in the first place — the libpq
  noise filter only covered `INSERT EDGE` / `GRAPH ...`, never plain
  INSERT. Documented for completeness.
- **018** no workaround shipped — server-side fix is the correct layer
  (native should project document columns like pgwire). Re-run the
  transport-parity table each NodeDB release; a phase-2 adapter
  fallback (JSON-expand `data` on native) is the contingency if upstream
  declines parity.

When NodeDB upstream fully resolves a bug, update the status above and
the per-bug doc, then ship the workaround removal as a separate PR
named `chore/remove-bugNNN-workaround`.
