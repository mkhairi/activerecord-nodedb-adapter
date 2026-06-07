# BUG-019 — vquery pg_catalog evaluator narrow expression shapes

## Status

OPEN upstream — retested 2026-06-07 against the **v0.3.0** release
(commit `25040fdf`; `SHOW server_version` reports `NodeDB 0.3.0`). The
0.3.0 changelog announces an in-process pg_catalog evaluator, but it
does not extend to any of the four expression shapes the AR adapter
needs: all four still error with
`virtual table query: unsupported on virtual catalog tables` /
`eval: unknown column`. Adapter ships unconditional bypass in
`0.1.0.alpha.7+`.

Prior retest: 2026-05-24 against commit `2aaec0fd` (still reported
`0.2.1`).

## Summary

NodeDB's pgwire pg_catalog handlers were rewritten to go through an
in-process `vquery` evaluator (upstream commits `eed703c6` and
`2330063a`, both 2026-05-23). The evaluator materialises virtual
catalog tables (`pg_type`, `pg_attribute`, `pg_class`, `pg_namespace`,
`pg_index`, `pg_authid`, `pg_database`, `_system.*`) and applies the
client `SELECT` against them, so `WHERE`, projection, aggregates,
`ORDER BY` and `LIMIT` work for the first time.

But the column set and expression vocabulary are narrower than what
ActiveRecord's PostgreSQLAdapter emits during connection setup and
schema reflection. Three concrete shapes fail with
`PG::FeatureNotSupported`:

1. **`::regclass` casts** — `WHERE attrelid = 'articles'::regclass`
   errors with `unsupported on virtual catalog tables: expression Cast { kind: DoubleColon, … data_type: Regclass }`.
2. **Cross-vtable joins** — `SELECT a.attname FROM pg_attribute a JOIN pg_class c ON a.attrelid = c.oid` errors with `eval: unknown column: attname` (joined-table column resolution not implemented).
3. **`ANY(current_schemas(false))` predicates** — AR's `tables`
   implementation emits `n.nspname = ANY(current_schemas(false))`
   which errors with `unsupported on virtual catalog tables: expression AnyOp { … right: Function(Function { name: ObjectName([Identifier(Ident { value: "current_schemas", … })]) … }) }`.
4. **`pg_type.typelem`** — AR's `load_additional_types` references
   `typelem`. vquery's materialised `pg_type` does not expose that
   column; the evaluator returns `eval: unknown column: typelem`.

The visible failure mode is misleading: AR closes the broken
connection mid-handshake, and NodeDB counts the abrupt close as an
auth event. The client sees `PG::ConnectionBad: FATAL: Password
authentication failed for user "nodedb"` even when the password is
correct, and repeated failures trip the lockout policy (see
"interaction" below).

## Reproduction

Live `psql` against the daemon — none of these depend on AR:

```sql
-- (1) regclass cast unsupported
SELECT attname FROM pg_attribute WHERE attrelid = 'articles'::regclass LIMIT 1;
-- ERROR: virtual table query: unsupported on virtual catalog tables: expression Cast { kind: DoubleColon, data_type: Regclass, ... }

-- (2) join unsupported
SELECT a.attname FROM pg_attribute a JOIN pg_class c ON a.attrelid = c.oid LIMIT 1;
-- ERROR: virtual table query: eval: unknown column: attname

-- (3) ANY(current_schemas(false)) unsupported — exact text AR emits in #tables
-- (paraphrased; trip the same shape via)
SELECT 1 FROM pg_class WHERE relnamespace = ANY (current_schemas(false));
-- ERROR: virtual table query: unsupported on virtual catalog tables: expression AnyOp { ... right: Function(... current_schemas ...) }

-- (4) typelem column not exposed
SELECT typelem FROM pg_type LIMIT 1;
-- ERROR: virtual table query: eval: unknown column: typelem
```

## Expected

vquery should either expose the columns and expression shapes that
PostgreSQL clients (including AR / libpq) routinely emit during
handshake and schema reflection, or the evaluator should fall back to
returning a materialised row stream when it encounters an unsupported
expression (so the client filters in-process). The current behaviour
makes any AR-based client unable to connect without an adapter-side
override.

## Interaction with lockout (BUG-019b)

AR closes the connection on the first vquery failure inside its
`configure_connection` / `load_additional_types` path. Upstream commit
`f9e19d84` (2026-05-22) wires `AuthRejection` into the pgwire lockout
sink, so each broken close increments the account's failed-login
counter. With the default `max_failed_logins = 5` / `lockout_duration_secs = 300`,
an unmodified AR app or rspec suite locks out the superuser within
seconds. Dev-mode workaround:

```toml
# /etc/nodedb/dev.toml
[auth]
mode                  = "password"
superuser_name        = "nodedb"
min_password_length   = 8
max_failed_logins     = 0     # disabled
lockout_duration_secs = 0
idle_timeout_secs     = 3600
max_connections_per_user = 0
password_expiry_days  = 0
audit_retention_days  = 0
```

Then `nodedb /etc/nodedb/dev.toml`. **Do not** ship this config to
production — disable lockout only while the vquery shapes are missing.

## Adapter workaround (`0.1.0.alpha.7`)

`NodedbAdapter` already had narrow native-protocol bypasses
(`return super unless native_transport?`) for catalog reflection
methods. Those guards now bypass on **every** transport, since pgwire
hits vquery limits in the exact same call sites:

| Method | Before | After |
| --- | --- | --- |
| `load_additional_types(oids = nil)` | super on pgwire | unconditional no-op (base types come from `initialize_type_map`'s static section) |
| `tables` / `data_sources` | super on pgwire | `collections` (SHOW COLLECTIONS) on every transport |
| `primary_keys(table_name)` | super on pgwire | `["id"]` if collection has an `id` column, else `[]` |
| `pk_and_sequence_for(_table)` | super on pgwire | `nil` (NodeDB has no sequences) |
| `indexes(table_name)` | super on pgwire | `[]` |
| `foreign_keys(table_name)` | super on pgwire | `[]` |
| `check_constraints(table_name)` | super on pgwire | `[]` |

`add_pg_decoders` is left calling `super` on pgwire — it works against
the vquery `pg_type` columns the evaluator does expose. Only the
`typelem`-referencing `load_additional_types` had to go.

`column_definitions` already uses `DESCRIBE` (see BUG-007); that path
is unaffected.

## Retirement

Retest each NodeDB release. Restore the `super` paths when:

- `pg_type.typelem` is projected by vquery, AND
- `ANY(current_schemas(false))` (or a NodeDB equivalent) resolves
  inside the evaluator, AND
- `'name'::regclass` casts evaluate, AND
- vquery resolves columns across joined virtual tables.

Until then the unconditional bypass is the correct shape — pgwire's
catalog evaluator and the native protocol share the same gap.

## Earlier history

The native-only guards landed in BUG-018 PR #44 and later, when the
native protocol had no pg_catalog backing at all. The vquery refactor
broadened the gap to pgwire; same code path, wider blast radius.
