# BUG-002: SELECT version() returns empty string

## Status: OPEN (retested 2026-05-10)

Still reproduces. `SELECT version()` returns an empty result.
`SHOW server_version` continues to work and returns `NodeDB 0.1.0`.

## Summary

`SELECT version()` returns an empty string instead of the NodeDB version.
`SHOW server_version` works correctly and returns `NodeDB 0.1.0`.

## Environment

- NodeDB version: `0.1.0`
- Client: `psql` (pgwire, port 6432)
- Date: 2026-05-09

## Reproduction

```sql
SELECT version();
-- Returns: (empty row)

SHOW server_version;
-- Returns: NodeDB 0.1.0
```

## Expected behaviour

`SELECT version()` should return the server version string, as it does in PostgreSQL.
Many PostgreSQL client libraries and ORMs call `SELECT version()` on connection to
identify the server.

## Impact

- **Severity**: Minor — workaround available via `SHOW server_version`
- ActiveRecord's `PostgreSQLAdapter` calls `SELECT version()` on connection; requires
  adapter override to use `SHOW server_version` instead.
- The `pg` gem's native `PQserverVersion()` also fails (see BUG-003).
