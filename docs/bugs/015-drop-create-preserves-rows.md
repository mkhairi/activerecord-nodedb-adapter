# BUG-015: DROP COLLECTION + CREATE COLLECTION resurrects old rows

## Status: RESOLVED (retested 2026-07-02 against upstream `3a06321e`)

Fixed upstream in NodeDB-Lab/nodedb#139 (commit c0a29495). CREATE of a
soft-deleted name now synchronously hard-purges the old collection
before registering the new one. Verified: no resurrected rows after
DROP + CREATE, and re-inserting a previously-used key succeeds with no
phantom PK conflict. `UNDROP` (without an intervening CREATE) is
unaffected.

### Earlier history (OPEN, 2026-05-10)

NodeDB's `DROP COLLECTION name` soft-deletes the storage within a
retention window. A subsequent `CREATE COLLECTION name (...)` of the
same name doesn't allocate fresh storage — it reattaches the existing
storage and the old rows reappear.

## Reproduction (psql)

```sql
CREATE COLLECTION x (version TEXT PRIMARY KEY) WITH (engine='document_strict');
INSERT INTO x (version) VALUES ('20260101000000');

DROP COLLECTION x;
SHOW COLLECTIONS;
-- x is gone

CREATE COLLECTION x (version TEXT PRIMARY KEY) WITH (engine='document_strict');
SELECT version FROM x;
--    version
-- ----------------
--  20260101000000   <-- old row resurrected
```

`UNDROP COLLECTION name` confirms NodeDB tracks the storage in a
tombstone within retention. Until the retention window expires, the
storage persists.

## Expected

A fresh `CREATE COLLECTION` after a `DROP` should allocate empty
storage. (Or at minimum, document the soft-delete semantics so callers
know to use `UNDROP` + `DELETE` to clear, or to wait for retention to
elapse.)

## Impact

Test suite hygiene gets confusing — collections that "should be empty"
after teardown bring back rows from earlier runs. Discovered while
testing schema_migrations round-trip in #24.

## Workaround

Sample app's `bin/setup` reconciles `schema_migrations` by clearing
versions whose target collection no longer exists, then running
migrations against whichever collections genuinely need creation.
General-purpose teardown should `DELETE FROM name` after re-creating to
guarantee an empty state.

## References

- GitHub issue: mkhairi/activerecord-nodedb-adapter#33
- Sample reconciliation: `../../sample_rails_app/bin/setup`
