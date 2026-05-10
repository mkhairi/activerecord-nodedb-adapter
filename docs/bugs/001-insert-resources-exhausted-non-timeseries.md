# BUG-001: INSERT returns "ResourcesExhausted" on all non-timeseries engines

## Status: RESOLVED (2026-05-10)

Fixed upstream in NodeDB Rust source. Two-part fix:

1. `nodedb/nodedb/src/config/engine.rs` — `EngineConfig::default()` only allocated
   budgets for 5 of 15 engines (Vector, Sparse, Crdt, Timeseries, Query). Added
   the missing 10: `document_schemaless`, `document_strict`, `kv`, `graph`, `fts`,
   `columnar`, `spatial`, `array`, `wal`, `bridge`. Updated `EngineByteBudgets`
   struct, `total_fraction()`, `validate()`, `to_byte_budgets()`, plus tests.
2. `nodedb/nodedb/src/memory/startup.rs` — `init_governor()` now inserts all 15
   `EngineId` variants into `engine_limits`, not just the original 5.

Root cause: `engine_pressure()` returned `PressureLevel::Emergency` for any
engine missing from the `Budget` HashMap (`unwrap_or(Emergency)`), which
short-circuited writes with `ResourcesExhausted` before they reached the engine.

Validation: 13/0/0 RSpec suite green after rebuild (debug 2m46s, release 11m23s).
INSERTs now work for document, KV, graph, etc.

## Summary

`INSERT` (and `UPSERT`) statements on document, KV, columnar, and document_strict
collections always fail with `ERROR: resources exhausted` / `ResourcesExhausted`.
Only the **timeseries engine accepts writes**. Reproducible on a completely fresh
data directory with no prior data.

## Environment

- NodeDB version: `0.1.0` (binary at `/home/khairi/Developments/nodedb/bin/nodedb`)
- Startup: `NODEDB_MEMORY_LIMIT=8GiB ./nodedb`
- Data dir: fresh (`~/.local/share/nodedb/` wiped before test)
- OS: Linux 6.8.0-111-generic
- Client: `psql` (PostgreSQL wire protocol, port 6432)
- Date: 2026-05-09

## Reproduction

```sql
-- Timeseries: WORKS
CREATE COLLECTION ts_probe (ts TIMESTAMP TIME_KEY, val FLOAT) WITH (engine='timeseries');
INSERT INTO ts_probe (ts, val) VALUES ('2026-05-09 10:00:00', 1.0);  -- OK
DROP COLLECTION ts_probe;

-- Document (schemaless): FAILS
CREATE COLLECTION doc_probe;
INSERT INTO doc_probe (id, name) VALUES ('a', 'Alice');  -- ERROR: resources exhausted
DROP COLLECTION doc_probe;

-- Document (object literal): FAILS
CREATE COLLECTION doc2;
INSERT INTO doc2 { id: 'a', name: 'Alice' };  -- ERROR: ResourcesExhausted
DROP COLLECTION doc2;

-- Document (strict): FAILS
CREATE COLLECTION doc_strict (id TEXT PRIMARY KEY, name TEXT) WITH (engine='document_strict');
INSERT INTO doc_strict (id, name) VALUES ('a', 'Alice');  -- ERROR: resources exhausted
DROP COLLECTION doc_strict;

-- KV: FAILS
CREATE COLLECTION kv_probe (key TEXT PRIMARY KEY, value TEXT) WITH (engine='kv');
INSERT INTO kv_probe (key, value) VALUES ('k1', 'v1');  -- ERROR: resources exhausted
DROP COLLECTION kv_probe;

-- Columnar: FAILS
CREATE COLLECTION col_probe (ts TIMESTAMP, val FLOAT) WITH (engine='columnar');
INSERT INTO col_probe (ts, val) VALUES ('2026-05-09 10:00:00', 1.0);  -- ERROR: resources exhausted
DROP COLLECTION col_probe;

-- UPSERT also fails (document)
CREATE COLLECTION upsert_test;
UPSERT INTO upsert_test (id, name) VALUES ('a', 'Alice');  -- ERROR: ResourcesExhausted
DROP COLLECTION upsert_test;
```

## Observed behaviour

`CREATE COLLECTION` and `DROP COLLECTION` succeed for all engine types.
`SELECT` works (returns empty result set).
`INSERT` / `UPSERT` returns `ERROR: resources exhausted` immediately on all engines
**except timeseries**.

## Expected behaviour

`INSERT` should succeed and the row should be retrievable via `SELECT`.

## Hypothesis

The error message `ResourcesExhausted` matches the backpressure mechanism described in
the changelog: _"Bounded backpressure — SPSC bridge (85%/95% thresholds)"_. The
document, KV, and columnar engines share a write path that goes through the Data Plane
SPSC bridge. The timeseries engine uses a separate ILP-optimised ingest path (_"ILP
ingest with adaptive batching"_) that bypasses the SPSC backpressure.

The bridge appears to be initialised at capacity (or the threshold is computed
incorrectly on startup) rather than empty, causing every write to immediately hit the
95% threshold and return `ResourcesExhausted` before any data is stored.

This is likely a bug in the SPSC bridge initialisation in the Data Plane startup
sequence (`nodedb/src/...`), or in how per-engine memory budgets are computed when
`NODEDB_MEMORY_LIMIT` is set as an env var rather than loaded from a config file.

## Workaround

None found. Only timeseries collections accept writes in this build.
**(Obsolete — fixed in source, see Status section above.)**

## Impact

- **Severity**: Critical — blocks all document, KV, columnar, and graph workloads
- **Scope**: All pgwire INSERT/UPSERT on non-timeseries engines
- **HTTP API**: Not tested (HTTP API requires a JWT bearer token, not password auth)

## Additional notes

- `SELECT 1+1` works
- `SHOW COLLECTIONS` works
- `CREATE COLLECTION` / `DROP COLLECTION` work for all engine types
- `SHOW server_version` returns `NodeDB 0.1.0`
- `SELECT version()` returns empty string (see BUG-002)
