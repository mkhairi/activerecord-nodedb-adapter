# BUG-011: spatial INSERT does not evaluate ST_GeomFromText

## Status: OPEN (2026-05-10)

`ST_GeomFromText('POINT(...)')` passed as an INSERT value is stored as the
literal SQL text rather than evaluated. ST_X / ST_Y / ST_Distance / ST_DWithin
all return NULL on the resulting column.

## Workaround

Use `engine='document_strict'` with explicit `lat FLOAT, lon FLOAT` columns
and compute haversine in Ruby. Sample app: `LocationsController#near`.

GitHub issue: mkhairi/activerecord-nodedb-adapter#13
