# Columnar Engine

NodeDB's columnar engine stores rows column-oriented for analytics:
aggregates, GROUP BY, and filtered scans over wide datasets.

## Setup

```ruby
# Migration
create_columnar :events do |t|
  t.text  :id, primary_key: true
  t.text  :region
  t.float :amount
end

# Model — standard AR reads work
class Event < ApplicationRecord
  self.table_name = "events"
end
```

## Queries

```ruby
Event.group(:region).sum(:amount)
# => { "east" => "16.0", "west" => "20.0" }   # values arrive as strings

Event.where("amount > ?", 8).count   # => 2
Event.where(region: "east").to_a
```

Raw SQL works the same way:

```sql
SELECT region, SUM(amount) FROM events GROUP BY region
SELECT id, amount FROM events WHERE amount > 8
```

Verified on current upstream (`3a06321e`): inserts, aggregates,
GROUP BY, and filtered scans all return correct results over pgwire.

## Quirks

- Columnar INSERTs return an `INSERT <n>` command tag (missing the OID
  slot libpq expects), so the pg gem prints a harmless
  `could not interpret result from server` warning to stderr. The
  insert succeeds.
- Distributed GROUP BY shuffle and ANALYZE-driven planning exist
  upstream (cluster deployments); single-node behaviour needs no
  configuration.
