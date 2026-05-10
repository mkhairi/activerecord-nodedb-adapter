# BUG-006: Unknown OID 0 for boolean column (type '16')

## Status: RESOLVED (retested 2026-05-10)

`SELECT TRUE, FALSE` returns the expected rows with no `unknown OID` warning
on stderr. NodeDB advertises the proper boolean OID in the column descriptor.

## Summary

NodeDB sends OID `0` for certain column types in the pgwire RowDescription message,
causing the pg gem to warn `unknown OID 0: failed to recognize type of '16'.
It will be treated as String.` PostgreSQL OID `16` is the boolean type.

## Environment

- NodeDB version: `0.1.0`
- Client: `pg` Ruby gem / ActiveRecord
- Date: 2026-05-09

## Reproduction

Any query that returns a boolean column triggers the warning.

## Expected behaviour

NodeDB should send the correct PostgreSQL OID for each column in the RowDescription
message: boolean OID 16, integer OID 23, float OID 701, etc.

## Impact

- **Severity**: Medium — boolean values returned as strings instead of true/false;
  bind parameters with unknown OID cause TypeError in ActiveRecord
- Workaround: use literal SQL interpolation instead of bind parameters for affected types
