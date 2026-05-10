# NodeDB upstream bug log

These are bugs the adapter has hit in NodeDB itself (not in this gem). Each is
documented with reproduction, expected behaviour, and the workaround the
adapter ships. They will be retired as upstream resolves them.

Re-tested: **2026-05-10**.

| ID | Title | Status |
| -- | ----- | ------ |
| 001 | INSERT returns `ResourcesExhausted` on non-timeseries engines | RESOLVED — fixed upstream in `nodedb/src/config/engine.rs` + `memory/startup.rs` |
| 002 | `SELECT version()` returns empty | OPEN |
| 003 | `PQserverVersion()` raises `PG::ConnectionBad` | OPEN |
| 004 | `DROP COLLECTION IF EXISTS` parses `IF` as a name when collection exists | OPEN (partial fix — works when collection is missing) |
| 005 | Prepared statements missing `RowDescription` before `DataRow` | RESOLVED |
| 006 | Unknown OID `0` for boolean column | RESOLVED |
| 007 | `pg_attribute` query returns duplicate `id` row | PARTIAL — adapter falls back to `DESCRIBE` |

## Adapter workarounds currently shipped

| Bug | Code path |
| --- | --------- |
| 002 | `nodedb_version` reads `SHOW server_version` |
| 003 | `database_version` / `get_database_version` return hardcoded `160000`; `check_version` is a no-op |
| 004 | `drop_collection(if_exists:)` rescues `ActiveRecord::StatementInvalid` matching `/does not exist/` |
| 007 | `column_definitions` falls back to `DESCRIBE` and de-duplicates the result |

When upstream fixes a bug, remove the workaround and bump the bug status here.
