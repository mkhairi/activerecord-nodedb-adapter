# BUG-028: DROP + CREATE of a BITEMPORAL collection resurrects the old versioned-store history

## Status: OPEN (discovered 2026-07-02 against upstream `3a06321e`)

The hard-purge that fixed document-store resurrection (CREATE over a
soft-deleted name) does not cover the **bitemporal versioned store**.
Dropping a BITEMPORAL collection and creating a new one with the same
name resurrects every old committed version:

- `AS OF SYSTEM TIME NULL` on the freshly created, never-written
  collection returns all versions from the previous incarnation
  (including rows from a differently-shaped schema).
- The plain read shows a corrupted merged row in the storage envelope
  shape (`id = <surrogate>, data = <byte>`).

Non-bitemporal collections purge correctly on re-CREATE (verified on
the same build).

## Reproduction (psql, pgwire 6432)

```sql
CREATE COLLECTION bt_res (id TEXT PRIMARY KEY, v TEXT, BITEMPORAL) ENGINE = document_strict;
INSERT INTO bt_res (id, v) VALUES ('a', 'one');
UPDATE bt_res SET v = 'two' WHERE id = 'a';
SELECT count(*) FROM bt_res AS OF SYSTEM TIME NULL;   -- 2 versions

DROP COLLECTION bt_res;
CREATE COLLECTION bt_res (id TEXT PRIMARY KEY, v TEXT, BITEMPORAL) ENGINE = document_strict;

SELECT * FROM bt_res AS OF SYSTEM TIME NULL;  -- old versions resurrected
SELECT * FROM bt_res;                          -- corrupted {id, data} row
```

## Expected

CREATE over a dropped name starts empty on every read path, including
the versioned store.

## Impact

- A bitemporal collection name is poisoned for the data directory's
  lifetime once dropped; only a full data-dir wipe clears it.
- Drop-and-recreate test/dev workflows are unusable with bitemporal
  collections.
- Same family as the graph edge-store ghosts (BUG-023 part 2):
  engine-specific stores are not enumerated by the purge path.

## Workaround

None client-side. Dev daemons: wipe the data directory (or use a fresh
collection name per incarnation).

## Tracking

GitHub issue: mkhairi/activerecord-nodedb-adapter#85
