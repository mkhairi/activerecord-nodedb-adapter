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

## Writes — the BUG-024 caveat

INSERT and DELETE committed inside explicit transactions are silently
lost on bitemporal collections, and AR wraps every `create!` /
`destroy` in one (`update!` happens to work). Write with a validated
raw autocommit INSERT:

```ruby
class AuditLog < ApplicationRecord
  validates :actor, :action, :recorded_at, presence: true

  def self.record!(attrs)
    log = new(attrs)
    log.id ||= SecureRandom.uuid
    raise ActiveRecord::RecordInvalid, log unless log.valid?

    cols   = %w[id actor action recorded_at]
    values = cols.map { |c| connection.quote(log.public_send(c)) }.join(", ")
    connection.execute("INSERT INTO #{table_name} (#{cols.join(', ')}) VALUES (#{values})")
    log
  end
end
```

Collapse to plain `create!` when upstream fixes the transactional
write path.

## Sharp edges (current upstream)

- **Never DROP + CREATE a bitemporal collection under the same name**
  — the old version history resurrects into the new collection and the
  current-state read shows a corrupted merged row (BUG-028). Only a
  fresh data directory clears a poisoned name.
- **Never name an ordinary column `bitemporal_id`** — on a *plain*
  document_strict collection that name silently routes writes into
  bitemporal machinery and transactional INSERTs vanish (BUG-026).
- `count(*)` over `AS OF SYSTEM TIME NULL` counts current state, not
  versions — count history rows client-side.

Full reproductions in [`docs/bugs/`](bugs/README.md); working demo in
the [nodedb-on-rails](https://github.com/mkhairi/nodedb-on-rails)
sample app (audit-log page).
