# BUG-022 — Native protocol routes `SHOW <anything>` through the session-parameter handler

## Status

RESOLVED — retested 2026-07-02 against upstream `3a06321e`. Fixed
upstream in commit 751b9cc3: the native SQL
dispatcher now runs the DDL/admin router before the session-variable
fallback, mirroring the pgwire fix. Verified over native: `SHOW STATS`
→ 22 `(name, value)` rows, `SHOW METRICS` → 26, `SHOW MEMORY` → 15
per-engine rows, `SHOW ROLES` → real column set (empty on a fresh
daemon, matching pgwire). Both retirement criteria below met.

Adapter fail-soft (`show_command` placeholder detection +
`native_show_placeholder?`) removed in
`chore/remove-bug022-workaround`; the native-transport specs now
assert real row sets.

### Earlier history

OPEN upstream — observed 2026-06-07 against the **v0.3.0** release
(commit `25040fdf`; `SHOW server_version` reports `NodeDB 0.3.0`).
Adapter `0.1.0.alpha.9+` returned `[]` from `show_stats`,
`show_metrics`, `show_memory`, and `show_roles` over native instead
of forwarding the placeholder row.

## Summary

NodeDB v0.3.0's pgwire surface routes `SHOW <command>` through the
DDL router before falling back to the session-parameter handler — the
fix landed in v0.3.0 under the commit message
> `fix(pgwire): route SHOW commands through DDL router before session-parameter fallback`

The native binary protocol did **not** get the same routing fix. Over
native (`port 6433`), `SHOW STATS`, `SHOW METRICS`, `SHOW MEMORY`,
`SHOW ROLES`, `SHOW TENANT`, etc. all fall through to the
session-parameter lookup. The session-parameter handler doesn't know
about these names, so it returns a single placeholder row:

```ruby
[{ "setting" => "" }]
```

regardless of which SHOW command was issued.

## Reproduction

```ruby
ENV["NODEDB_TRANSPORT"] = "native"
conn = ActiveRecord::Base.connection

# Pgwire returns 22 rows of (name, value) counters.
# Native returns one placeholder row.
conn.execute("SHOW STATS").to_a
# => [{ "setting" => "" }]

conn.execute("SHOW METRICS").to_a
# => [{ "setting" => "" }]

conn.execute("SHOW MEMORY").to_a
# => [{ "setting" => "" }]

conn.execute("SHOW ROLES").to_a
# => [{ "setting" => "" }]
```

Same SQL over pgwire (port 6432) returns the real result sets (22 /
26 / 15 / N rows respectively).

`SHOW TENANT <id>` is partially affected — it returns the correct
tenant snapshot over both transports because the session-parameter
fallback for `TENANT` happens to be wired up (it sees the current
session's tenant). The columnar / counter-style SHOW commands have
no such fallback and degrade to the placeholder shape.

## Expected

The native protocol should resolve `SHOW <command>` the same way
pgwire does — route through the DDL handler first, fall back to
session-parameter lookup only for `SHOW <session_var>`.

## Adapter response (`0.1.0.alpha.9+`)

`NodedbAdapter#show_command` (private) detects the placeholder shape
on native:

```ruby
def show_command(sql)
  rows = select_all(sql).to_a
  return [] if native_transport? && native_show_placeholder?(rows)

  rows
end

def native_show_placeholder?(rows)
  rows.length == 1 &&
    rows.first.keys == ["setting"] &&
    rows.first["setting"].to_s.empty?
end
```

`show_stats`, `show_metrics`, `show_memory`, and `show_roles` all
flow through `show_command`, so each returns `[]` over native instead
of leaking the misleading placeholder row to callers. Pgwire
behaviour is unchanged.

Specs covering the four helpers ship in
`spec/native_transport_spec.rb` (adapter PR #65).

## Downstream impact

The `nodedb-on-rails` `/server_info` Operations section renders four
of these helpers as Tabler cards. With this adapter fix in place, the
cards now render their empty-state hints when the app is launched
with `NODEDB_TRANSPORT=native` instead of showing a misleading
"1 rows" header above an empty placeholder.

## Retirement criteria

- `SHOW STATS`, `SHOW METRICS`, `SHOW MEMORY`, and `SHOW ROLES` over
  the native protocol return the same column layouts and row counts
  as pgwire (22 / 26 / 15 / N).
- The `{"setting" => ""}` placeholder no longer surfaces from any
  routed-through-DDL `SHOW` command on native.
