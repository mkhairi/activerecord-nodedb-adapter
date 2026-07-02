# BUG-003: PQserverVersion() raises PG::ConnectionBad

## Status: OPEN (retested 2026-07-02 against upstream `3a06321e`)

Still reproduces, root cause now narrowed. Upstream's #142 fix added
`server_version_num` to the startup ParameterStatus burst (verified:
`conn.parameter_status("server_version_num")` returns `"150000"`), but
libpq does not read that parameter — `PQserverVersion()` is computed by
parsing the **`server_version`** ParameterStatus string only
(`pqSaveParameterStatus` in fe-connect.c). NodeDB sends
`server_version = "NodeDB 0.3.0"`, whose non-numeric prefix fails
libpq's version parse, so `PQserverVersion()` returns 0 and the pg gem
raises. Confirmed on pg 1.6.3 / libpq 18.0.1:

```ruby
conn.server_version
# PG::ConnectionBad: PQserverVersion() can't get server version
conn.parameter_status("server_version")      # => "NodeDB 0.3.0"
conn.parameter_status("server_version_num")  # => "150000"
```

Client-agnostic confirmation with stock psql 18.4 (Debian, libpq 18,
`postgres:18` Docker image): psql's built-in variables — populated
directly from `PQserverVersion()` — show the parse failure without any
Ruby in the loop:

```
$ psql -h 127.0.0.1 -p 6432 -U nodedb -d nodedb \
    -c '\echo SERVER_VERSION_NUM=:SERVER_VERSION_NUM SERVER_VERSION_NAME=:SERVER_VERSION_NAME'
SERVER_VERSION_NUM=0 SERVER_VERSION_NAME=NodeDB 0.3.0
```

psql itself degrades gracefully on 0 (queries work; version-gated
features may misbehave); the Ruby pg gem raises on 0. Same root cause.

Upstream fix needed: send a numeric-parseable `server_version`
ParameterStatus — e.g. `15.0 (NodeDB 0.3.0)`; libpq parses the leading
digits and ignores the trailing parenthetical, exactly how it handles
real PostgreSQL's `16.0 (Ubuntu ...)` strings. Adapter workaround
(hardcoded `database_version`) still required.

### Earlier history (OPEN, retested 2026-05-10)

Still reproduced. `conn.server_version` raised:
`PG::ConnectionBad: PQserverVersion() can't get server version`.

## Summary

The `pg` gem's native `conn.server_version` method (which wraps libpq's
`PQserverVersion()`) raises `PG::ConnectionBad` when connected to NodeDB. NodeDB
advertises a non-numeric `server_version` string in the pgwire handshake
parameter messages, which libpq cannot parse into a version integer.

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
