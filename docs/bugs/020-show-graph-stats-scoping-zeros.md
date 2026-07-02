# BUG-020 — `SHOW GRAPH STATS '<collection>'` returns all-zero counters

## Status

RESOLVED — retested 2026-07-02 against upstream `3a06321e`. Fixed
upstream (`summary_key` canonicalization on
both insert and scoped-read paths). Both retirement criteria below
verified: the scoped form returns the same counters as the matching
tenant-wide row, and the `collection` cell is bare in both forms.

The `NodeDB::Graph#graph_stats` tenant-wide + Ruby-filter workaround
(PR #55) is still shipped; removal tracked as
`chore/remove-bug020-workaround`.

### Earlier history

OPEN upstream — observed 2026-06-07 against the **v0.3.0** release
(commit `25040fdf`; `SHOW server_version` reports `NodeDB 0.3.0`).
Adapter `0.1.0.alpha.8+` ships a tenant-wide + Ruby-filter workaround
in `NodeDB::Graph#graph_stats` (see PR #55).

## Summary

NodeDB v0.3.0 added persistent O(1) graph-stats counters surfaced via
`SHOW GRAPH STATS [<collection>] [VERBOSE] [AS OF SYSTEM TIME <ms>]`.
The tenant-wide form (no collection) returns the correct counts. The
single-collection form parses successfully but the returned row is
all-zero, even when the tenant-wide form proves that collection holds
real edges.

## Reproduction

```sql
nodedb=> CREATE COLLECTION g020 (id TEXT) ENGINE = document_strict;
CREATE COLLECTION
nodedb=> INSERT INTO g020 (id) VALUES ('alice'), ('bob'), ('carol');
INSERT 0 3
nodedb=> GRAPH INSERT EDGE IN g020 FROM 'alice' TO 'bob' TYPE 'knows' PROPERTIES '{}';
INSERT EDGE
nodedb=> GRAPH INSERT EDGE IN g020 FROM 'bob' TO 'carol' TYPE 'knows' PROPERTIES '{}';
INSERT EDGE

-- Tenant-wide form: correct.
nodedb=> SHOW GRAPH STATS;
 collection | node_count | edge_count | distinct_label_count |             labels
------------+------------+------------+----------------------+---------------------------------
 "g020"     |          4 |          2 |                    1 | [{"count":2,"label":"knows"}]

-- Scoped form: zeros, same name, same query.
nodedb=> SHOW GRAPH STATS 'g020';
 collection | node_count | edge_count | distinct_label_count | labels
------------+------------+------------+----------------------+--------
 g020       |          0 |          0 |                    0 | []
```

Note also that the tenant-wide form returns the collection name
JSON-quoted (`"g020"`) while the scoped form returns it bare (`g020`),
hinting at a lookup-key mismatch between the broadcast aggregator and
the single-collection path.

## Expected

The scoped form should return the same row the tenant-wide form returns
for the named collection — `node_count = 4`, `edge_count = 2`,
`distinct_label_count = 1`, `labels = [{"count":2,"label":"knows"}]`.

## Adapter workaround

`NodeDB::Graph#graph_stats` fetches the tenant-wide form via
`connection.graph_stats(verbose:, as_of:)` and filters the result set
in Ruby by stripping the JSON quotes from `row["collection"]` and
comparing against the model's `table_name`. This is an O(N) scan over
every graph collection in the tenant — acceptable for an alpha demo,
not optimal for tenants with thousands of collections.

The connection-level `connection.graph_stats(collection: …)` does NOT
filter; it issues the SQL as written so callers can observe the
upstream bug if they want to reproduce. The model-level fallback only
lives in the `Graph` concern's class method.

Retire the Ruby filter when the upstream scoping path returns the
right counters.

## Retirement criteria

- `SHOW GRAPH STATS '<collection>'` returns the same `node_count`,
  `edge_count`, `distinct_label_count`, and `labels` as the matching
  row from the tenant-wide form.
- The scoped form's `collection` value matches the tenant-wide form's
  `collection` value (both JSON-quoted, or both bare — consistent
  either way).
