# BUG-029: count(*) materializes a row counter that DELETE never decrements

## Status: OPEN (isolated 2026-07-03 against upstream `3a06321e`)

The first `count(*)` on a document collection materializes a
per-collection row counter. Subsequent INSERTs maintain it correctly;
**DELETEs never decrement it** — the count stays stale forever while
scans report the truth. If no `count(*)` ran before the DELETE, a
fresh count is correct: the staleness is tied to the materialized
counter, not the DELETE.

Likely the long-standing "COUNT parity" gap first noticed in May.

## Reproduction (psql, pgwire 6432)

```sql
CREATE COLLECTION cnt3 (id TEXT PRIMARY KEY) ENGINE = document_strict;
INSERT INTO cnt3 (id) VALUES ('a');
INSERT INTO cnt3 (id) VALUES ('b');

SELECT count(*) FROM cnt3;    -- 2 (correct; counter materializes here)

INSERT INTO cnt3 (id) VALUES ('c');
SELECT count(*) FROM cnt3;    -- 3 (correct; INSERT maintains it)

DELETE FROM cnt3 WHERE id = 'c';
SELECT count(*) FROM cnt3;    -- 3 (WRONG — truth is 2)
SELECT id FROM cnt3;          -- a, b (scan is correct)
```

Control: with no prior `count(*)`, the post-delete count is correct.

## Expected

`count(*)` equals scan cardinality after any committed DML.

## Impact

- Every ORM count (`Model.count`, `DB[:t].count`, pagination totals)
  drifts upward permanently once rows are deleted on a
  previously-counted collection.
- Count-based test assertions fail or pass vacuously depending on
  operation order.
- Related quirk: `count(*)` on an empty collection returns zero rows
  instead of a `0` row.

## Workaround

None client-side. Assert cardinality via scans
(`SELECT id FROM t` length) around delete operations — the Sequel
adapter's spec suite does this.

## Tracking

GitHub issue: mkhairi/activerecord-nodedb-adapter#90
