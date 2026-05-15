# BUG-011: spatial INSERT does not evaluate ST_GeomFromText

## Status: CHANGED — NodeDB v0.2.1 (retested 2026-05-15)

Behaviour shifted from silent-text-store to a hard error:

```
ERROR:  unsupported: value expression: ST_GeomFromText('POINT(-74 40)')
```

Net effect: spatial INSERT with `ST_GeomFromText` now fails loudly instead
of silently storing the literal expression. Better diagnostics, but the
spatial engine is still effectively unusable for real coordinate work.
Sample app workaround (document_strict + Ruby haversine) still required.

### Earlier history (OPEN, 2026-05-10)

`ST_GeomFromText('POINT(...)')` passed as an INSERT value is stored as the
literal SQL text rather than evaluated. ST_X / ST_Y / ST_Distance / ST_DWithin
all return NULL on the resulting column.

## Workaround

Use `engine='document_strict'` with explicit `lat FLOAT, lon FLOAT` columns
and compute haversine in Ruby. Sample app: `LocationsController#near`.

GitHub issue: mkhairi/activerecord-nodedb-adapter#13
