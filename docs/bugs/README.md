# NodeDB upstream bug log

NodeDB-side bugs the adapter has had to dance around. Each entry has a
matching `<id>-<slug>.md` doc with reproduction, expected behaviour, and
adapter workaround.

Last refreshed: **2026-05-15** against **NodeDB v0.2.1**.

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

When NodeDB upstream fully resolves a bug, update the status above and
the per-bug doc, then ship the workaround removal as a separate PR
named `chore/remove-bugNNN-workaround`.
