# BUG-008: DELETE inside transaction silently dropped on COMMIT

## Status: RESOLVED upstream — NodeDB v0.2.1 (retested 2026-05-15)

`DELETE` inside `BEGIN; ... COMMIT;` now persists:

```sql
INSERT INTO t (id) VALUES ('x');
BEGIN;
DELETE FROM t WHERE id = 'x';
COMMIT;
SELECT id FROM t;
-- (0 rows)
```

Adapter `NodedbAdapter#exec_delete` workaround (re-issuing DELETE outside the
AR-opened txn) is now redundant but harmless; leave in place for backward
compatibility with older NodeDB binaries.

### Earlier history (OPEN, 2026-05-10)

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
