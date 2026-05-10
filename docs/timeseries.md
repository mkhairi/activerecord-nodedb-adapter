# Timeseries Engine

NodeDB's timeseries engine is optimised for append-heavy time data: ILP ingest,
continuous aggregation, PromQL, and time-bucketed queries.

## Setup

```ruby
# Migration
create_collection :metrics, engine: :timeseries

# Model
class Metric < ApplicationRecord
  include NodeDB::Timeseries
  self.primary_key = nil  # timeseries collections have no surrogate PK
end
```

## Queries

```ruby
# Filter by time range
Metric.since(1.hour.ago)
Metric.until_time(Time.current)
Metric.since(1.hour.ago).until_time(30.minutes.ago)

# Combine with standard AR scopes
Metric.since(1.day.ago).where(host: "web-01").order(:ts)

# time_bucket — returns a SQL fragment for use in select/group
Metric.select(Metric.time_bucket("5 minutes", column: :ts))
      .select("host, AVG(cpu) AS avg_cpu")
      .group("bucket, host")
      .order("bucket")
```

## SQL emitted

```sql
SELECT * FROM metrics WHERE ts > '2026-05-09 09:00:00'
SELECT time_bucket('5 minutes', ts) AS bucket, host, AVG(cpu) AS avg_cpu
  FROM metrics GROUP BY bucket, host ORDER BY bucket
```

## time_bucket options

```ruby
Metric.time_bucket("1 hour",   column: :ts, as: :bucket)
Metric.time_bucket("5 minutes", column: :created_at, as: :window)
```
