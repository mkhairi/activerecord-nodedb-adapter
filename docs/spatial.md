# Spatial Engine

NodeDB spatial uses R*-tree indexing, geohash, H3, and OGC predicates
compatible with PostGIS function names.

> **Status on current upstream (`3a06321e`):** the geometry **write
> path works** — `ST_GeomFromText` / `ST_MakePoint` / `ST_GeomFromWKB`
> evaluate on INSERT and round-trip as GeoJSON on raw column reads.
> The **read-side accessors are still broken** (`ST_AsText` / `ST_X` /
> `ST_Y` return empty; `ST_DWithin` rejects constructor arguments), so
> the concern's predicate helpers below do not return usable results
> yet. For working distance queries today, use the document_strict +
> Ruby haversine pattern at the bottom.

## Setup

```ruby
# Migration
create_collection :places, engine: :spatial do |t|
  t.column :id,   "INT PRIMARY KEY"
  t.column :geom, "GEOMETRY"
  t.text   :label
end

# Model
class Place < ApplicationRecord
  include NodeDB::Spatial
end
```

## Geometry writes (working)

```ruby
conn = ActiveRecord::Base.connection
conn.execute(<<~SQL)
  INSERT INTO places (id, geom, label)
  VALUES (1, ST_MakePoint(101.6869, 3.1390), 'KL')
SQL

conn.select_all("SELECT id, geom, label FROM places").to_a
# => [{ "id" => "1",
#       "geom" => "{\"type\":\"Point\",\"coordinates\":[101.6869,3.139]}",
#       "label" => "KL" }]
```

## Predicate helpers (blocked on upstream read-side functions)

The concern ships the PostGIS-shaped API; it emits correct SQL but the
underlying functions don't evaluate on current upstream:

```ruby
Place.within_distance(lat: 40.75, lon: -73.98, meters: 1000)
Place.order_by_distance(lat: 40.75, lon: -73.98).limit(10)
Place.within_bbox(min_lon: -74.0, min_lat: 40.7, max_lon: -73.9, max_lat: 40.8)
```

```sql
SELECT * FROM places WHERE ST_DWithin(geom, ST_Point(-73.9967, 40.7484), 1000)
SELECT *, ST_Distance(geom, ST_Point(-73.9967, 40.7484)) AS distance FROM places ORDER BY distance
SELECT * FROM places WHERE geom && ST_MakeEnvelope(-74.0, 40.7, -73.9, 40.8, 4326)
```

## Working pattern today: document_strict + Ruby haversine

What the sample app ships — plain lat/lon columns, distance in Ruby:

```ruby
create_document_strict :locations do |t|
  t.text  :id, primary_key: true
  t.text  :name
  t.float :lat
  t.float :lon
end

class Location < ApplicationRecord
  RADIUS_KM = 6371.0

  def self.near(lat, lon, km)
    all.select { |l| haversine(lat, lon, l.lat, l.lon) <= km }
  end

  def self.haversine(lat1, lon1, lat2, lon2)
    d_lat = (lat2 - lat1) * Math::PI / 180
    d_lon = (lon2 - lon1) * Math::PI / 180
    a = Math.sin(d_lat / 2)**2 +
        Math.cos(lat1 * Math::PI / 180) * Math.cos(lat2 * Math::PI / 180) *
        Math.sin(d_lon / 2)**2
    RADIUS_KM * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  end
end
```

Typed scalar columns round-trip correctly on `engine: :spatial` too, so
the schema can carry `geom` alongside `lat`/`lon` and switch to the
predicate helpers when upstream lands the read-side functions.
