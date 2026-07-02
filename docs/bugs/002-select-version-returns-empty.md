# BUG-002: SELECT version() returns empty string

## Status: RESOLVED (retested 2026-07-02 against upstream `3a06321e`)

Fixed upstream in commits 15ae22e6 / e137985e /
f9e21b3f). `SELECT version()` returns
`PostgreSQL 15.0 (NodeDB) on x86_64`;
`current_setting('server_version_num')` returns `150000`;
`current_setting('server_version')` returns `NodeDB 0.3.0`.

Note: `PQserverVersion()` still raises — that is BUG-003 (libpq parses
the `server_version` ParameterStatus string, and `NodeDB 0.3.0` has a
non-numeric prefix). Still open, tracked separately.

### Earlier history (OPEN, retested 2026-05-10)

`SELECT version()` returned an empty result. `SHOW server_version`
continued to work and returned `NodeDB 0.1.0`.

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
