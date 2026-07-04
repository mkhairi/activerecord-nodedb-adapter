# Bitemporal Collections

NodeDB's `BITEMPORAL` modifier keeps every committed version of every
row in a `document_strict` collection. Current-state reads are plain
ActiveRecord; time-travel reads use the `AS OF SYSTEM TIME` scan
suffix.

## Setup

```ruby
# Migration
create_collection :audit_logs, engine: :document_strict, bitemporal: true do |t|
  t.text :id, primary_key: true
  t.text :actor
  t.text :action
  t.text :recorded_at
end
```

The adapter emits the `ENGINE = document_strict` suffix spelling for
bitemporal DDL — the `WITH (engine=...)` form builds a broken
bitemporal schema upstream (BUG-027).

## Reads

```ruby
# Current state — plain ActiveRecord
AuditLog.where(actor: "alice")
AuditLog.count

conn = ActiveRecord::Base.connection

# Full version history: every committed version, each row carrying
# `_ts_system` (commit timestamp in ms)
conn.select_all("SELECT * FROM audit_logs AS OF SYSTEM TIME NULL").to_a

# Rows current at a past instant (ms epoch)
conn.select_all("SELECT * FROM audit_logs AS OF SYSTEM TIME #{1.hour.ago.to_i * 1000}").to_a
```

`AS OF SYSTEM TIME` is a FROM-clause suffix — it doesn't compose with
AR relations, so history rows come back as hashes. `WHERE` composes;
`ORDER BY` and computed columns don't (sort client-side on
`_ts_system`).

## Writes

Plain ActiveRecord on current upstream: `create!` / `update!` /
`destroy` persist and version normally (the old BUG-024 transactional
write loss is fixed). Prefer the `NodeDB::Bitemporal` concern for
time-travel reads:

```ruby
class AuditLog < ApplicationRecord
  include NodeDB::Bitemporal
  validates :actor, :action, :recorded_at, presence: true
end

AuditLog.versions        # full audit trail, oldest first
AuditLog.history("l-42") # one record's trail
AuditLog.as_of(1.hour.ago)
```

## Sharp edges (current upstream)

- **Never DROP + CREATE a bitemporal collection under the same name**
  — the old version history resurrects into the new collection and the
  current-state read shows a corrupted merged row (BUG-028). Only a
  fresh data directory clears a poisoned name.
- `count(*)` over `AS OF SYSTEM TIME NULL` counts current state, not
  versions — count history rows client-side.

Full reproductions in the
[issue tracker](https://github.com/mkhairi/activerecord-nodedb-adapter/issues?q=%22%5Bupstream%3ANodeDB%5D%22);
working demo in the
[nodedb-on-rails](https://github.com/mkhairi/nodedb-on-rails)
sample app (audit-log page).
