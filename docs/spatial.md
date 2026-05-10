# Spatial Engine

NodeDB spatial uses R*-tree indexing, geohash, H3, and OGC predicates compatible
with PostGIS function names.

## Setup

```ruby
# Migration
create_collection :locations, engine: :spatial

# Model
class Location < ApplicationRecord
  include NodeDB::Spatial
end
```

## Queries

```ruby
# Nearest within distance (metres)
Location.within_distance(lat: 40.7484, lon: -73.9967, meters: 1000)

# Order by distance (nearest first), adds `distance` column to results
Location.order_by_distance(lat: 40.7484, lon: -73.9967)
        .select("name, distance")
        .limit(10)

# Bounding box filter
Location.within_bbox(min_lon: -74.0, min_lat: 40.7,
                     max_lon: -73.9, max_lat: 40.8)
```

## SQL emitted

```sql
SELECT * FROM locations WHERE ST_DWithin(geom, ST_Point(-73.9967, 40.7484), 1000)
SELECT *, ST_Distance(geom, ST_Point(-73.9967, 40.7484)) AS distance FROM locations ORDER BY distance
SELECT * FROM locations WHERE geom && ST_MakeEnvelope(-74.0, 40.7, -73.9, 40.8, 4326)
```
