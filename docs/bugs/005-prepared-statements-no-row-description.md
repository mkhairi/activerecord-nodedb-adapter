# BUG-005: Prepared statements missing RowDescription before DataRow

## Status: RESOLVED (retested 2026-05-10)

Prepared-statement round-trip now works against the rebuilt NodeDB binary:

```ruby
conn.prepare("p1", "SELECT 1+1 AS r")
conn.exec_prepared("p1").to_a
# => [{"r" => "2"}]
```

The adapter still ships with `prepared_statements = false` because the failure
mode was binary-message-level and could regress; consider re-enabling once a
broader test pass confirms parameter binding round-trips end-to-end.

## Summary

NodeDB does not send a `RowDescription` (pgwire `T` message) before `DataRow` (`D`)
messages when executing prepared statements via the extended query protocol
(`Parse` → `Bind` → `Execute`). This causes `PG::UnableToSend: server sent data
("D" message) without prior row description ("T" message)`.

## Environment

- NodeDB version: `0.1.0`
- Client: `pg` Ruby gem (libpq extended query protocol)
- Date: 2026-05-09
- **Re-tested 2026-05-10**: Error message changed in rebuild. Simple query protocol now raises `ERROR: unsupported: value literal: $1` — NodeDB does not recognise `$1` placeholders even in simple query mode. Extended query protocol (prepared statements) still broken. Workaround (`prepared_statements: false`) still required; avoid parameterised SQL entirely.

## Reproduction

```ruby
conn = PG.connect(host: 'localhost', port: 6432, user: 'nodedb', password: '...')
# Create a timeseries collection and insert a row (timeseries INSERT works)
# Then query with a parameterized statement:
conn.prepare("stmt1", "SELECT * FROM ts_probe WHERE timestamp > $1")
conn.exec_prepared("stmt1", [1778319000000])
# => PG::UnableToSend: server sent data ("D" message) without prior row description ("T" message)
```

Also triggered by ActiveRecord's parameterized `where` clause:
```ruby
Model.where("timestamp > ?", some_value).to_a
# => ActiveRecord::StatementInvalid: PG::UnableToSend: ...
```

## Expected behaviour

The server must send `RowDescription` before `DataRow` in the extended query
protocol, per the pgwire specification. Simple query protocol (`exec`) works
correctly for the same SQL.

## Impact

- **Severity**: High — breaks all parameterized queries via the extended query protocol
- All ActiveRecord `.where("col > ?", value)` calls fail
- Workaround: force `prepared_statements: false` so AR uses simple query protocol

## Workaround (activerecord-nodedb-adapter)

```ruby
def initialize(connection, logger, connection_options, config)
  super(connection, logger, connection_options, config.merge(prepared_statements: false))
end
```

## Related

- Similar issue exists in ClickHouse adapter (addressed same way: `@prepared_statements = false`)
