# BUG-033: a PK point-lookup miss poisons that key for the rest of the session

## Status: OPEN (2026-07-04) — upstream `f8a4df44` (v0.3.0 main head)

Discovered on the build that fixed the transactional-DELETE phantom
(BUG-008 family). This is the inverse shape: a *missing*-row phantom.

## Summary

Within one session, a bare PK-equality point-lookup that finds nothing
caches that emptiness for the key. A subsequent INSERT of the key
succeeds (and UPDATE sees the row), but the same `WHERE id = <key>`
read keeps returning 0 rows for the rest of the session:

- scans (`SELECT ... FROM t`) see the row;
- compound predicates (`WHERE id = <key> AND <anything>`) see the row;
- only the bare PK-equality shape stays poisoned;
- INSERT and UPDATE of the key do NOT invalidate the cached miss;
- a lookup with no prior miss behaves correctly;
- fresh sessions are unaffected.

## Reproduction (single psql session, port 6432)

```sql
CREATE COLLECTION negcache (id TEXT PRIMARY KEY, v TEXT) WITH (engine='document_strict');

SELECT v FROM negcache WHERE id = 'k';          -- (0 rows)  <- primes the poison
INSERT INTO negcache (id, v) VALUES ('k','val'); -- OK
UPDATE negcache SET v = 'val2' WHERE id = 'k';   -- UPDATE 1  <- write path sees it
SELECT v FROM negcache WHERE id = 'k';           -- (0 rows)  <- WRONG, expected 'val2'
SELECT v FROM negcache WHERE id = 'k' AND v = 'val2';  -- 1 row <- compound bypasses
SELECT id, v FROM negcache;                      -- 1 row     <- scan sees it
```

## Impact

Any same-session check-then-insert-then-read pattern on a PK:
`find_by` → `create!` → `find_by` returns nothing;
`find_or_create_by` followed by a reload misses. The adapter's
advisory-lock machinery read exactly this shape (probe the lock row,
insert it, re-read it) — reworked to scan the (tiny) lock collection
instead.

## Adapter workaround (partial)

`AdvisoryLocks#advisory_lock_row` scans `ar_advisory_locks` and filters
client-side. No general workaround is shipped for arbitrary model
reads — rewriting every PK point-lookup into a scan or a padded
compound predicate would be wrong for large collections. Fix belongs
upstream.

## Upstream fix sketch

The shared point-read cache introduced with the transactional
point-delete/put rework needs invalidation on INSERT/UPSERT of a key
whose miss was cached (the same path already invalidates for the
compound-predicate planner shape).

## Upstream

Not yet reported upstream.
