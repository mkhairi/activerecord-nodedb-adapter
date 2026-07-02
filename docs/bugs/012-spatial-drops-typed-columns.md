# BUG-012: spatial engine drops non-geom typed columns

## Status: RESOLVED (retested 2026-07-02 against upstream `3a06321e`)

Typed scalar columns on `engine='spatial'` now round-trip:

```sql
CREATE COLLECTION sp12 (id INT PRIMARY KEY, geom GEOMETRY, lat FLOAT, lon FLOAT, label TEXT) ENGINE = spatial;
INSERT INTO sp12 (id, geom, lat, lon, label) VALUES (1, ST_MakePoint(1,2), 3.5, 4.5, 'p1');
SELECT id, lat, lon, label FROM sp12;
-- 1 | 3.5 | 4.5 | p1
```

Was previously untestable while BUG-011 blocked every spatial INSERT;
verified fixed on the same build where BUG-011's write path landed.

### Earlier history (OPEN, 2026-05-10)

Typed scalar columns (e.g. `lat FLOAT, lon FLOAT`) declared on a
`engine='spatial'` collection appear in DESCRIBE but values silently drop
on INSERT. The same schema with `engine='document_strict'` round-trips.

## Workaround

Use `document_strict` for collections that need both geometry and typed
scalars. Sample app falls back to lat/lon columns + Ruby haversine.

GitHub issue: mkhairi/activerecord-nodedb-adapter#14
