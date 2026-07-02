# BUG-021 — Reads against a `BITEMPORAL` collection return zero rows

## Status

RESOLVED — retested 2026-07-02 against upstream `3a06321e`. Fixed
upstream in NodeDB-Lab/nodedb#135 (commits 6548e7c7 / 7e3eb92b):
bitemporal collections now route the default scan and streaming
aggregates to the versioned current-state scan, and the pgwire
projection parser strips the temporal clause so `AS OF SYSTEM TIME`
reprojects into user columns. Verified: plain `SELECT`, `count(*)`,
and `AS OF SYSTEM TIME NOW()` all return the projected row. No adapter
workaround ever shipped (none was possible), so nothing to retire.

### Earlier history

OPEN upstream — observed 2026-06-07 against the **v0.3.0** release
(commit `25040fdf`; `SHOW server_version` reports `NodeDB 0.3.0`).
No adapter workaround possible; bitemporal collections are effectively
write-only on this build.

## Summary

NodeDB v0.3.0 stabilised the `BITEMPORAL` collection modifier (parsed,
schema accepts the flag, `DESCRIBE` reflects it, INSERTs are accepted
with a normal `OK` tag). But every form of `SELECT` against a
bitemporal collection returns zero rows:

- plain `SELECT * FROM bt;`
- column-scoped `SELECT id, … FROM bt;`
- `SELECT … FROM bt AS OF SYSTEM TIME NOW();`
- `SELECT … FROM bt AS OF SYSTEM TIME <ms-integer>;`

The `count(*)` aggregate likewise returns `0`. There is no error; the
result set is just empty. INSERTs leave no observable trace through
the SQL surface.

## Reproduction

```sql
nodedb=> CREATE COLLECTION bug021
       (id TEXT PRIMARY KEY, name TEXT, BITEMPORAL)
       ENGINE = document_strict;
CREATE COLLECTION

nodedb=> INSERT INTO bug021 (id, name) VALUES ('a', 'first');
INSERT 0 1

-- Every SELECT shape comes back empty.
nodedb=> SELECT * FROM bug021;
 result
--------
(0 rows)

nodedb=> SELECT count(*) FROM bug021;
 count
-------
     0

nodedb=> SELECT * FROM bug021 AS OF SYSTEM TIME NOW();
 result
--------
(0 rows)
```

The same `INSERT` against a non-bitemporal `document_strict`
collection round-trips correctly (verified in
`nodedb-on-rails/scripts/feature_smoke.rb`, 21/21 pgwire).

## Expected

Plain `SELECT` against a bitemporal collection should return the
currently-valid system-time snapshot (the live version). `AS OF
SYSTEM TIME NOW()` should return the same rows. `AS OF SYSTEM TIME
<ms>` for a timestamp after the INSERT should also return them.

## Adapter response

None possible at the SQL layer. The sample app's `AuditLog` demo
(`mkhairi/nodedb-on-rails`, PR #10) ships the
`create_collection ..., bitemporal: true` migration and an explicit
read-path workaround that unwraps the `{data,id}` blob shape, but
since no rows ever come back from the upstream SELECT path the table
stays empty regardless. The demo banner calls this out and points
here.

If upstream lands a partial fix that returns the raw `{data,id}` blob
shape (BUG-018 territory) for bitemporal collections, the adapter
will still need the blob-unwrap workaround on top.

## Related upstream surface

- `nodedb-sql/src/temporal.rs` — `valid_from_ms` / `valid_until_ms`
  qualifiers for bitemporal scans
- `nodedb-sql/src/ddl_ast/collection_type.rs` — `bitemporal: bool` flag
  on `StrictSchema`
- `nodedb-sql/src/ddl_ast/parse/collection/body.rs:47` — body-string
  keyword search that sets the flag on parse
- `nodedb-types/src/namespace.rs` — `LatestVersion` namespace added
  for O(1) live-version lookups, but the SQL surface does not yet
  consume it for default-namespace reads

## Retirement criteria

- A non-bitemporal-qualified `SELECT * FROM bt;` returns rows in the
  same shape as a non-bitemporal `document_strict` SELECT.
- `AS OF SYSTEM TIME NOW()` is consistent with the default read.
- `AS OF SYSTEM TIME <ms>` selects the rows as of the given system
  time and respects the bitemporal namespace structure.
