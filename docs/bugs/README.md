# NodeDB upstream bug log

NodeDB-side bugs the adapter has had to dance around. Each entry has a
matching `<id>-<slug>.md` doc with reproduction, expected behaviour, and
adapter workaround.

Last refreshed: **2026-05-10**.

| ID  | Title | Status |
| --- | ----- | ------ |
| 001 | INSERT returns `ResourcesExhausted` on non-timeseries engines | RESOLVED — fixed upstream in `nodedb/src/config/engine.rs` + `memory/startup.rs` |
| 002 | `SELECT version()` returns empty | OPEN |
| 003 | `PQserverVersion()` raises `PG::ConnectionBad` | OPEN |
| 004 | `DROP COLLECTION IF EXISTS` parses `IF` as a name when collection exists | OPEN (partial — works when collection is missing) |
| 005 | Prepared statements missing `RowDescription` before `DataRow` | RESOLVED |
| 006 | Unknown OID `0` for boolean column | RESOLVED |
| 007 | `pg_attribute` query returns duplicate `id` row | PARTIAL — adapter falls back to `DESCRIBE` |
| 008 | DELETE inside transaction silently dropped | OPEN — adapter re-issues outside the AR-opened txn (PR #10) |
| 009 | INSERT command tag missing OID slot | OPEN — produces harmless libpq stderr noise |
| 010 | `text_match()` predicate doesn't filter rows | OPEN — adapter filters by `bm25_score` (PR #15) |
| 011 | Spatial INSERT does not evaluate `ST_GeomFromText` | OPEN — sample app uses `document_strict` + Ruby haversine |
| 012 | Spatial engine drops non-geometry typed columns on INSERT | OPEN — sample app uses `document_strict` instead |
| 013 | FTS fuzzy mode returns wrapped JSON | OPEN — adapter unwraps in `fts_search` (PR #17) |
| 014 | `pg_try_advisory_lock` / `pg_advisory_unlock` missing | OPEN — adapter no-op stubs (PR #30) |
| 015 | DROP + CREATE resurrects old rows in retention window | OPEN — sample app reconciles in `bin/setup` |
| 016 | `document_strict` 2nd INSERT collides on empty `id` when PK on non-`id` column | OPEN — adapter stores user keys in built-in `id` column (PR #24) |

## Adapter workarounds currently shipped

| Bug | Code path |
| --- | --------- |
| 002 | `nodedb_version` reads `SHOW server_version` |
| 003 | `database_version` / `get_database_version` return hardcoded `160000`; `check_version` is a no-op |
| 004 | `drop_collection(if_exists:)` rescues `ActiveRecord::StatementInvalid` matching `/does not exist/` |
| 007 | `column_definitions` falls back to `DESCRIBE` and de-duplicates the result |
| 008 | `NodedbAdapter#exec_delete` re-issues DELETE outside any AR-opened transaction |
| 010, 013 | `NodeDB::FullTextSearch#fts_search` projects `id, bm25_score`, filters nulls, JSON-unwraps fuzzy rows |
| 014 | `NodedbAdapter#get_advisory_lock` / `#release_advisory_lock` no-op pair returning `true` |
| 016 | `Nodedb::SchemaMigration` / `Nodedb::InternalMetadata` declare PK on the built-in `id` column |

When NodeDB upstream resolves a bug, remove the workaround and bump the
status above to RESOLVED.
