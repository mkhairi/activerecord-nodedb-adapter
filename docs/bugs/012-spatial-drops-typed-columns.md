# BUG-012: spatial engine drops non-geom typed columns

## Status: OPEN (2026-05-10)

Typed scalar columns (e.g. `lat FLOAT, lon FLOAT`) declared on a
`engine='spatial'` collection appear in DESCRIBE but values silently drop
on INSERT. The same schema with `engine='document_strict'` round-trips.

## Workaround

Use `document_strict` for collections that need both geometry and typed
scalars. Sample app falls back to lat/lon columns + Ruby haversine.

GitHub issue: mkhairi/activerecord-nodedb-adapter#14
