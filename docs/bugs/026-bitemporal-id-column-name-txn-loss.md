# BUG-026: user column named `bitemporal_id` silently triggers bitemporal txn write loss on plain document_strict

## Status: OPEN (discovered 2026-07-02 against upstream `3a06321e`)

A plain (non-BITEMPORAL) `document_strict` collection that merely
**contains a user column named `bitemporal_id`** inherits BUG-024's
transactional write loss: INSERTs committed inside `BEGIN...COMMIT`
silently vanish (autocommit persists). The identical schema with the
column renamed persists correctly. The name appears to be reserved
server-side and routes writes into bitemporal machinery.

`valid_from` / `valid_to` / `transaction_from` / `transaction_to`
column names are innocent — isolated to `bitemporal_id` only.

## Reproduction (psql, pgwire 6432)

```sql
CREATE COLLECTION f1 (id TEXT PRIMARY KEY, name TEXT, bitemporal_id TEXT) ENGINE = document_strict;

INSERT INTO f1 (id, name) VALUES ('a1', 'auto');   -- autocommit: persists
BEGIN;
INSERT INTO f1 (id, name) VALUES ('a2', 'txn');
COMMIT;
SELECT id, name FROM f1;
--  a1 | auto        <- 'a2' silently lost

-- control: same schema, column renamed to `extra` -> txn INSERT persists
```

## Expected

User column names must not change transaction semantics. Either
reject `bitemporal_id` loudly at CREATE COLLECTION, or treat it as an
ordinary column.

## Impact

- Blocks kufu/activerecord-bitemporal-style app-level bitemporality
  (their schema convention is exactly a `bitemporal_id` column) even
  after the BUG-025 dequalification workaround.
- Foot-gun for any schema using the name.
- Same failure signature as BUG-024; likely shared root cause.

## Workaround

Avoid the column name. If adopting an app-level bitemporal library,
configure a different id column name if supported; otherwise blocked
on upstream.

## Tracking

GitHub issue: mkhairi/activerecord-nodedb-adapter#76
