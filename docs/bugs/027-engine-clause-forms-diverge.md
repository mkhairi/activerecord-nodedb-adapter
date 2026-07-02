# BUG-027: CREATE COLLECTION engine spellings diverge — WITH+BITEMPORAL builds broken schema; ENGINE= suffix ignores timeseries engine

## Status: OPEN (discovered 2026-07-02 against upstream `3a06321e`)

NodeDB accepts two spellings for the engine clause, resolved through
different code paths — each broken for a different case:

1. `WITH (engine='document_strict')` + the `BITEMPORAL` flag builds a
   **broken bitemporal schema**: plain SELECT leaks internal columns
   (`__system_from_ms`, `__valid_from_ms`, `__valid_until_ms`) and
   `AS OF SYSTEM TIME NULL` projects only `_ts_system`.
2. `ENGINE = timeseries` (suffix form) silently **fails to apply the
   engine**: the collection behaves like a document engine and the
   second INSERT dies with a duplicate-empty-PK violation.

The complementary forms are clean: `ENGINE = document_strict` +
BITEMPORAL projects correctly; `WITH (engine='timeseries')` ingests
correctly.

## Reproduction (psql, pgwire 6432)

```sql
CREATE COLLECTION bt_w (id TEXT PRIMARY KEY, actor TEXT, BITEMPORAL) WITH (engine='document_strict');
INSERT INTO bt_w (id, actor) VALUES ('1', 'a');
SELECT * FROM bt_w;                          -- internals leak (__system_from_ms, ...)
SELECT * FROM bt_w AS OF SYSTEM TIME NULL;   -- only _ts_system projected

CREATE COLLECTION ts_e (ts TIMESTAMP TIME_KEY, value FLOAT) ENGINE = timeseries;
INSERT INTO ts_e (ts, value) VALUES ('2026-05-09 10:00:00', 1.0);
INSERT INTO ts_e (ts, value) VALUES ('2026-05-09 10:05:00', 2.0);
-- ERROR: duplicate key value '' violates primary-key uniqueness on 'ts_e'
```

## Expected

Both spellings produce identical collections for every engine and
modifier combination — or one is rejected at parse time.

## Workaround (shipped)

`nodedb-ruby`'s `SQL::Collection.create` picks the spelling per flag:
`ENGINE =` suffix when `BITEMPORAL` is present, `WITH (engine=...)`
otherwise. Collapse to one spelling when upstream unifies the paths.

Note: bitemporal collections created by earlier adapter versions carry
the broken WITH-form schema permanently — drop and recreate them.

## Tracking

GitHub issue: mkhairi/activerecord-nodedb-adapter#83
