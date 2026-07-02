# BUG-024: bitemporal collections lose INSERT and DELETE committed inside explicit transactions

## Status: OPEN (discovered 2026-07-02 against upstream `3a06321e`)

DML committed inside `BEGIN; ...; COMMIT;` on a `BITEMPORAL` collection
is partially lost:

| Statement | autocommit | inside BEGIN...COMMIT |
| --------- | ---------- | --------------------- |
| INSERT    | persists   | **silently lost**     |
| UPDATE    | persists   | persists              |
| DELETE    | persists   | **silently lost** (row survives) |

The INSERT returns `RETURNING` data and the COMMIT succeeds — the row
is simply absent from every subsequent read. Non-bitemporal
`document_strict` collections persist all three inside transactions
(modulo the known BUG-008 DELETE case).

## Reproduction (psql, pgwire 6432)

```sql
CREATE COLLECTION bt_txn (id TEXT PRIMARY KEY, v TEXT, BITEMPORAL) ENGINE = document_strict;

BEGIN;
INSERT INTO bt_txn (id, v) VALUES ('t1', 'in-txn');
COMMIT;
SELECT * FROM bt_txn;
-- (0 rows)                     <- committed INSERT lost

INSERT INTO bt_txn (id, v) VALUES ('t2', 'autocommit');
SELECT * FROM bt_txn;
--  t2 | autocommit             <- autocommit INSERT persists

BEGIN;
DELETE FROM bt_txn WHERE id = 't2';
COMMIT;
SELECT * FROM bt_txn;
--  t2 | autocommit             <- committed DELETE lost, row survives
```

## Expected

Transactional DML on bitemporal collections should persist exactly
like autocommit DML does (and like transactional DML on non-bitemporal
collections).

## Impact

**ActiveRecord cannot write bitemporal collections**: AR wraps every
`create!` / `destroy` in a transaction, so inserts vanish and destroys
no-op. `update!` happens to work. Likely the same root as BUG-008
(transactional DML visibility), extended to the versioned bitemporal
write path — the txn commit hook appears not to reach the versioned
store that bitemporal reads route to.

## Adapter response

The `NodeDB::Bitemporal` read-helper concern (`.as_of` / `.versions` /
`.history`) is **parked unmerged** on branch
`feat/bitemporal-read-helpers` — helpers verified against live NodeDB
via raw SQL, but model specs cannot create fixture data through AR.
No workaround shipped: extending the BUG-008 commit-outside-txn hack
to INSERTs would break AR transaction semantics wholesale.

## Tracking

GitHub issue: mkhairi/activerecord-nodedb-adapter#72
