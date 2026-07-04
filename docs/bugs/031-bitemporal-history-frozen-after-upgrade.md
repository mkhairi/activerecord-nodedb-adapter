# BUG-031: bitemporal versioned store stops recording after a daemon upgrade

## Status: OPEN (2026-07-04) — upstream `67c4572d` (v0.3.0 main head)

## Summary

A BITEMPORAL collection created on an earlier build (`3a06321e`,
2026-07-02) silently stops appending to its versioned store once the
daemon is upgraded to `67c4572d` on the same data directory:

- plain `SELECT` / `COUNT(*)` see rows written after the upgrade;
- `SELECT ... AS OF SYSTEM TIME NULL` (the full version history) only
  returns versions written *before* the upgrade — post-upgrade writes
  never appear, with no error on the write path.

Collections created *after* the upgrade version correctly. The failure
is silent data loss on the audit trail — the primary reason to use a
bitemporal collection.

## Reproduction

On build `3a06321e`:

```sql
CREATE COLLECTION bt (id TEXT PRIMARY KEY, v TEXT, BITEMPORAL)
  ENGINE = document_strict;
INSERT INTO bt (id, v) VALUES ('a','one');
```

Upgrade the daemon binary to `67c4572d` (same data dir), then:

```sql
INSERT INTO bt (id, v) VALUES ('b','two');
SELECT count(*) FROM bt;                    -- 2 (both rows visible)
SELECT * FROM bt AS OF SYSTEM TIME NULL;    -- only ('a','one') versions;
                                            -- 'b' has NO history entries
```

Control: `CREATE COLLECTION bt2 (... BITEMPORAL) ...` on `67c4572d`,
INSERT + UPDATE → `AS OF SYSTEM TIME NULL` returns every version
including `_ts_system`.

## Related

BUG-028 (DROP + CREATE resurrects prior versioned-store history under
the same name) still reproduces on `67c4572d` — retested 2026-07-04.
Recreating a frozen collection therefore brings its ghost history (and
a stale plain row) back.

## Impact on this adapter / sample app

`nodedb-on-rails`'s `audit_logs` collection predates the upgrade: its
`AuditLog.versions` (AS OF scan) returns only pre-upgrade versions
while writes keep succeeding — `feature_smoke`'s `bitemporal.versions`
check fails. No adapter-side workaround is possible; the sample app's
collection must be recreated on the new build (accepting BUG-028
ghosts) or the data dir wiped.

## Upstream

Not yet reported upstream.
