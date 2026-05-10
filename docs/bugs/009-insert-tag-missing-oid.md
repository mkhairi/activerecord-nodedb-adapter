# BUG-009: INSERT command tag missing OID slot triggers libpq noise

## Status: OPEN (2026-05-10)

## Summary

NodeDB returns the command tag `INSERT 1` for successful INSERTs on
document collections. Standard PostgreSQL emits `INSERT <oid> <rowcount>`.
libpq's tag parser expects two integers and prints
`could not interpret result from server: INSERT 1` to fd 2 for every
INSERT.

## Impact

Stderr noise on every INSERT through any libpq client. The query succeeds;
only the warning is wrong.

## Expected

NodeDB emits `INSERT 0 N` (PostgreSQL-conformant), or omits the tag
entirely.

## Workaround

The graph fix (`NodeDB::Graph::LIBPQ_NOISE_RE` + `silence_libpq_noise`)
already covers `GRAPH …` and `INSERT EDGE`. Extending the regex to cover
`INSERT \d+` would suppress this too at the cost of hiding a class of
malformed tag warnings — the proper fix is upstream conformance.

## Tracking

GitHub issue: mkhairi/activerecord-nodedb-adapter#9
