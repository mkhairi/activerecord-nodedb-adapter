# BUG-023: MATCH `IN <collection>` ignores collection scope; DROP leaves edge-store entries visible

## Status: OPEN (discovered 2026-07-02 against upstream `3a06321e`)

Two related defects in the graph engine's collection scoping, observed
over pgwire while probing the new MATCH executor:

1. `MATCH (n)-[]->(m) IN <collection> RETURN n, m` ignores the
   `IN <collection>` scope and returns edges from **every** collection
   in the tenant's edge store — including collections that were
   `DROP`ped. The edge-type filter (`-[:type]->`) does work, which
   makes the leak worse: a type-scoped MATCH inside collection B
   returns another collection's edges of that type.
2. Plain `DROP COLLECTION` does not remove the collection's graph
   edge-store entries. `SHOW GRAPH STATS` keeps listing dropped
   collections with live counters, and their edges stay reachable via
   MATCH. (The hard-purge that resolved BUG-015 fires only on
   re-`CREATE` of the same name, not on plain `DROP`.)

## Reproduction (psql, pgwire 6432)

```sql
CREATE COLLECTION leak_a (id TEXT) ENGINE = document_strict;
INSERT INTO leak_a (id) VALUES ('a1'), ('a2');
GRAPH INSERT EDGE IN leak_a FROM 'a1' TO 'a2' TYPE 'rel_a' PROPERTIES '{}';
DROP COLLECTION leak_a;

CREATE COLLECTION leak_b (id TEXT) ENGINE = document_strict;
INSERT INTO leak_b (id) VALUES ('b1'), ('b2');
GRAPH INSERT EDGE IN leak_b FROM 'b1' TO 'b2' TYPE 'rel_b' PROPERTIES '{}';

MATCH (n)-[]->(m) IN leak_b RETURN n, m;
--  b1 | b2        <- correct
--  a1 | a2        <- leaked from DROPPED leak_a
--  (plus edges from every other collection ever created in the tenant)

MATCH (n)-[:rel_a]->(m) IN leak_b RETURN n, m;
--  a1 | a2        <- another collection's edge type, inside leak_b scope

SHOW GRAPH STATS;
-- lists leak_a (dropped) with node_count=2, edge_count=1, plus every
-- previously dropped test collection with live counters
```

## Expected

1. `MATCH ... IN <collection>` returns only that collection's edges.
2. `DROP COLLECTION` removes (or hides via `is_active` filtering) the
   collection's edge-store entries from MATCH and `SHOW GRAPH STATS`.

## Impact

- **Severity: High** for any multi-collection graph usage — MATCH
  results are cross-contaminated, so query results are wrong, not just
  noisy.
- Test suites amplify it: every spec-run collection leaves permanent
  edge ghosts (10+ dead `test_social_*` entries after one rspec run).
- The adapter's Graph concern cannot safely expose MATCH until scoping
  works (or the adapter post-filters, which is expensive and racy).

## Workaround

None shipped. MATCH exposure in the Graph concern is **on hold** on
this bug. `GRAPH TRAVERSE` and the other existing graph helpers are
unaffected (they resolve through per-collection entry points).

## Tracking

GitHub issue: mkhairi/activerecord-nodedb-adapter#70
