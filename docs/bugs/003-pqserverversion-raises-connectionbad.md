# BUG-003: PQserverVersion() raises PG::ConnectionBad

## Status: OPEN (retested 2026-05-10)

Still reproduces. `conn.server_version` raises:
`PG::ConnectionBad: PQserverVersion() can't get server version`.

## Summary

The `pg` gem's native `conn.server_version` method (which wraps libpq's
`PQserverVersion()`) raises `PG::ConnectionBad` when connected to NodeDB. NodeDB does
not advertise a server version integer in the pgwire handshake parameter messages.

## Environment

- NodeDB version: `0.1.0`
- Client: `pg` Ruby gem v1.5+ via libpq
- Date: 2026-05-09

## Reproduction

```ruby
require 'pg'
conn = PG.connect(host: 'localhost', port: 6432, user: 'nodedb', password: '...')
conn.server_version
# => PG::ConnectionBad: PQserverVersion() can't get server version
```

## Expected behaviour

`PQserverVersion()` should return an integer (e.g. `160000` for 16.0) or `0` without
raising an exception. PostgreSQL sets `server_version_num` in the startup parameter
messages; NodeDB does not, causing libpq to raise instead of returning 0.

## Impact

- **Severity**: Medium — breaks all PostgreSQL client libraries that call
  `PQserverVersion()` during connection setup
- ActiveRecord `PostgreSQLAdapter` calls this in `get_database_version` on every
  connection; requires full override
- Workaround: override `get_database_version` and `database_version` in the adapter
  to return a hardcoded integer and skip the libpq call

## Workaround (activerecord-nodedb-adapter)

```ruby
def database_version    = 160000
def get_database_version = 160000
def check_version;      end
```
