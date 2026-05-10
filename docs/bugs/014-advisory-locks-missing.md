# BUG-014: pg_try_advisory_lock / pg_advisory_unlock missing

## Status: OPEN (2026-05-10)

NodeDB pgwire does not implement PostgreSQL's session-scoped advisory
lock functions (`pg_try_advisory_lock(N)` / `pg_advisory_unlock(N)`).
ActiveRecord wraps `db:migrate` in one of these locks to block concurrent
migration runs across processes — the call returns an error / wrong type
on NodeDB and AR raises `ActiveRecord::ConcurrentMigrationError` on every
`rails db:migrate`.

## Reproduction

```sql
SELECT pg_try_advisory_lock(1);
-- ERROR / unknown function
```

## Expected

`pg_try_advisory_lock(N)` returns boolean `true` on success / `false` if
already held by another session. `pg_advisory_unlock(N)` releases.
Standard PostgreSQL semantics — no transaction binding, session-scoped.

## Impact

Every `rails db:migrate` raises `ConcurrentMigrationError`. AR also calls
the same primitives for fixture loading and structure dumps in some
configurations.

## Workaround in this adapter

`NodedbAdapter#get_advisory_lock` and `#release_advisory_lock` are
overridden to a no-op pair returning `true`. Loses cross-process
migration safety; acceptable for single-instance alpha. Removed once
NodeDB ships the primitives.

## References

- GitHub issue: mkhairi/activerecord-nodedb-adapter#32
- Code: `lib/active_record/connection_adapters/nodedb_adapter.rb`
- Workaround landed: PR #30
