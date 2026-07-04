# BUG-032: databases created by CREATE DATABASE are unusable — catalog reads ignore the session database

## Status: OPEN (2026-07-04) — upstream `67c4572d` (v0.3.0 main head)

Regression relative to `3a06321e` (2026-07-02), where a CREATE
DATABASE'd database worked end-to-end (this suite ran against one for
two days).

## Summary

On a database created via `CREATE DATABASE`, DDL **writes** are homed
to that database but every catalog **read** resolves against the
default database only:

- `CREATE COLLECTION` succeeds (a second create errors with
  `already exists`, and `SHOW DATABASES` shows the database's
  collection count incrementing);
- but `DESCRIBE`, `SELECT`, and `SHOW COLLECTIONS` in the same session
  say the collection does not exist — `SHOW COLLECTIONS` lists the
  *default* database's collections regardless of the session database.

Net: non-default databases are write-only; every collection created
there is unreachable (and accumulates as a phantom until
`DROP DATABASE ... CASCADE`).

## Reproduction (psql, port 6432)

```sql
-- session on the default database
CREATE DATABASE probe_db;

-- new session: psql -d probe_db
CREATE COLLECTION pd_c (id TEXT PRIMARY KEY) WITH (engine='document_strict');
-- CREATE COLLECTION
DESCRIBE pd_c;
-- ERROR:  collection 'pd_c' not found
SELECT * FROM pd_c;
-- ERROR:  table not found: pd_c
CREATE COLLECTION pd_c (id TEXT PRIMARY KEY) WITH (engine='document_strict');
-- ERROR:  collection 'pd_c' already exists        <- write side sees it
SHOW COLLECTIONS;
-- lists the DEFAULT database's collections, not probe_db's
```

Daemon restart does not repair visibility.

## Impact on this adapter

The spec suite defaulted to a dedicated `nodedb_test` database; on a
fresh data directory that database must be CREATE DATABASE'd and every
integration spec then fails with `collection ... not found` right
after a successful `create_collection`. The suite default now points
at the default `nodedb` database (specs isolate via random-suffixed
collections); override with `NODEDB_URL` when multi-database works
again.

## Upstream

Not yet reported upstream.
