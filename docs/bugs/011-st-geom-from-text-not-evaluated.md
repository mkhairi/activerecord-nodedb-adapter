# BUG-011: spatial INSERT does not evaluate ST_GeomFromText

## Status: RESOLVED (retested 2026-07-02 against upstream `3a06321e`)

Fixed upstream in commit 90eb3124.
`ST_GeomFromText`, `ST_MakePoint`, and `ST_GeomFromWKB` now evaluate
as geometry constructors on INSERT; the value is stored as GeoJSON and
round-trips on a raw column read:

```sql
INSERT INTO sp (id, geom, label) VALUES (1, ST_GeomFromText('POINT(1 2)'), 'p1');
SELECT id, geom, label FROM sp;
-- 1 | {"type":"Point","coordinates":[1.0,2.0]} | p1
```

Residual (separate issue, not this bug): read-side accessors
`ST_AsText` / `ST_X` / `ST_Y` return empty and `ST_DWithin` rejects a
`ST_MakePoint` argument, so spatial predicates are still unusable.
Sample-app haversine fallback stays until those land.

### Earlier history (CHANGED, NodeDB v0.2.1, retested 2026-05-15)

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
