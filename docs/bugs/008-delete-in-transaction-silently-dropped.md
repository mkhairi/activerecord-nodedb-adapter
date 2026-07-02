# BUG-008: DELETE inside transaction silently dropped on COMMIT

## Status: RESHAPED (retested 2026-07-02 against upstream `3a06321e`)

The bug changed form. On the current build the transactional DELETE
**does persist** — full scans show the row gone for every PK form
(implicit, explicit `NOT NULL`, TEXT and INT). What remains is a
**stale primary-key point-lookup phantom**:

```sql
CREATE COLLECTION p1 (id TEXT NOT NULL PRIMARY KEY, v TEXT) ENGINE = document_strict;
INSERT INTO p1 (id, v) VALUES ('x', 'first');
BEGIN; DELETE FROM p1 WHERE id = 'x'; COMMIT;

SELECT id, v FROM p1;                -- (0 rows)   scan: deleted
SELECT id, v FROM p1 WHERE id='x';   -- x | first  point-lookup: PHANTOM
```

The phantom persists until the key is re-inserted (which succeeds
without a duplicate-key error and heals the lookup). Autocommit DELETE
is clean on both paths. Tell: in-txn DELETE returns a bare `OK`
command tag; autocommit returns `DELETE 1`.

Earlier retests (including 2026-07-02 morning) used
`SELECT ... WHERE id = ...` as the post-delete probe and read the
phantom as "row still present" — the old "DELETE silently dropped"
description is outdated, and the `NOT NULL`-conditional distinction is
gone.

**Adapter `exec_delete` workaround stays**: re-issuing the DELETE
outside the transaction takes the clean autocommit path, so AR
`record.destroy` followed by `find(id)` sees no phantom.

## Upstream tracking

Reported upstream 2026-07-02 (stale PK point-lookup
after committed transactional DELETE).

## Earlier history

### PARTIAL — NodeDB v0.2.1 (re-retested 2026-05-15)

Fix is **conditional on collection schema**:

- `id TEXT PRIMARY KEY` (implicit `NOT NULL`) — DELETE inside
  `BEGIN; ... COMMIT;` now persists correctly.
- `id TEXT NOT NULL PRIMARY KEY` (explicit `NOT NULL`) — DELETE is still
  silently dropped on COMMIT.

ActiveRecord emits `"id" text NOT NULL PRIMARY KEY` for every primary key
column, so every adapter-driven `record.destroy` still hits the broken path.
**Adapter `NodedbAdapter#exec_delete` workaround remains required on v0.2.1+.**

### Minimal reproduction (psql, fresh collection name to dodge BUG-015)

```sql
-- WORKS (implicit NOT NULL)
CREATE COLLECTION t_ok (id TEXT PRIMARY KEY) WITH (engine='document_strict');
INSERT INTO t_ok (id) VALUES ('x');
BEGIN; DELETE FROM t_ok WHERE id='x'; COMMIT;
SELECT id FROM t_ok WHERE id='x';   -- (0 rows)

-- BROKEN (explicit NOT NULL — what AR emits)
CREATE COLLECTION t_ar (id TEXT NOT NULL PRIMARY KEY) WITH (engine='document_strict');
INSERT INTO t_ar (id) VALUES ('x');
BEGIN; DELETE FROM t_ar WHERE id='x'; COMMIT;
SELECT id FROM t_ar WHERE id='x';   -- row still present
```

(Use a fresh collection name on every retry — BUG-015's DROP+CREATE retention
window will resurrect deleted rows if the name was used recently and mask
this bug's behaviour.)

### Earlier history (OPEN, 2026-05-10; "RESOLVED" mis-call 2026-05-15 morning)

An earlier 2026-05-15 retest used DDL without an explicit `NOT NULL` and
saw DELETE persisting; that retest flipped the doc/issue to RESOLVED. The
afternoon re-retest discovered the schema-conditional nature of the fix and
walked the status back to PARTIAL — AR's DDL still triggers the bug.

## Summary

`DELETE` statements that run inside a `BEGIN; ... COMMIT;` transaction are
silently dropped on commit. The same statement run outside a transaction
deletes the row correctly. `UPDATE` inside a transaction works fine — only
`DELETE` is affected.

## Reproduction (psql)

```sql
INSERT INTO articles (id, title, body) VALUES ('txn_test', 'a', 'b');

BEGIN;
DELETE FROM articles WHERE id = 'txn_test';
COMMIT;

SELECT id FROM articles WHERE id = 'txn_test';
-- row still present
```

## Impact

ActiveRecord wraps `record.destroy` in a transaction by default:

```
BEGIN
DELETE FROM "articles" WHERE "articles"."id" = '...'
COMMIT
```

So `Article.find(id).destroy` silently no-ops. `record.destroyed?` returns
`true`, but the row remains.

## Workaround in this adapter

`NodedbAdapter#exec_delete` and `delete` are overridden to commit the
current real transaction before issuing the DELETE, then begin a fresh
transaction so AR's wrapping `COMMIT` still completes cleanly. This is a
**semantic compromise** — DELETE no longer rolls back if the surrounding
transaction raises later. Acceptable for alpha; will be removed when
upstream fixes the bug.

Affected paths:

- `record.destroy` / `record.destroy!`
- `Model.where(...).destroy_all`
- Any custom code path that wraps DELETE in `transaction { }`

Unaffected (works without the workaround):

- `Model.delete(id)`
- `Model.where(...).delete_all`

## Expected

DELETE inside a transaction should persist exactly like UPDATE inside a
transaction does today.

## Tracking

GitHub issue: mkhairi/activerecord-nodedb-adapter#8
