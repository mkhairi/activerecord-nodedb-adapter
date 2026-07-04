# BUG-014: pg_try_advisory_lock / pg_advisory_unlock missing

## Status: UPSTREAM WON'T-FIX — closed upstream 2026-07-04; application-level workaround SHIPPED

Upstream closed the report as won't-fix: the pgwire surface is a
deliberately thin compatibility layer, and advisory-lock-style
coordination would be designed as a native-surface primitive if a
concrete need arises. No pgwire implementation is coming.

The adapter therefore implements the migration mutex itself
(replacing the old always-`true` no-op stubs):

- `ar_advisory_locks` — a `document_strict` collection
  (`id TEXT PRIMARY KEY, owner TEXT, acquired_at TEXT`), created on
  first use.
- `get_advisory_lock(id)` — atomic `INSERT` of the lock key; the PK
  uniqueness constraint rejects a second holder server-side
  (`constraint violation: unique: duplicate key value ...`). Returns
  `false` when held, so `ActiveRecord::ConcurrentMigrationError` fires
  correctly for a genuinely concurrent `db:migrate`.
- `release_advisory_lock(id)` — deletes the row only when `owner`
  matches this connection's token (a per-adapter-instance UUID).
- Stale-lock recovery: rows older than `advisory_lock_ttl` seconds
  (connection config, default 3600) are stolen on acquire, since a
  crashed holder can't auto-release.

On top of the migrator contract, a block API modeled on the
`with_advisory_lock` gem ships for app-level coordination:

- `with_advisory_lock(name, timeout_seconds: nil) { ... }` — yields
  under the lock and releases in an `ensure` (crash-in-process safe);
  returns the block value, or `false` when not acquired.
  `timeout_seconds: 0` = try once, a positive value polls with
  randomized backoff until the deadline, `nil` = wait forever.
- `with_advisory_lock!` — same, raises
  `Nodedb::FailedToAcquireLock` instead of returning `false`.
- Reentrant per thread: re-requesting a held lock just yields; only
  the outermost exit releases.
- `advisory_lock_exists?(name)` introspection; lock keys can be
  namespaced with the `NODEDB_ADVISORY_LOCK_PREFIX` env var.

Semantic differences vs PostgreSQL advisory locks (accepted):
not session-scoped — a crash leaves the row until the TTL steal
(the block API's ensure-release narrows this to hard crashes).
Cross-process migration safety is restored; the old no-op stubs
provided none.

Note: lock-row reads scan the collection instead of `WHERE id =`
point-lookups — BUG-033 poisons a key's PK-equality reads after a
miss, and the lock flow reads a key right before inserting it.

### Earlier retest (PARTIAL — NodeDB v0.2.1, 2026-05-15)

Functions were recognised by the parser but returned empty results
(silent no-ops, no boolean):

```sql
SELECT pg_try_advisory_lock(1);  -- single empty row, no value
SELECT pg_advisory_unlock(1);    -- same
```

### Earlier history (OPEN, 2026-05-10)

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

Collection-based lock (see Status above). Retire only if upstream
ships a native coordination primitive worth switching to.

## References

- GitHub issue: mkhairi/activerecord-nodedb-adapter#32
- Code: `lib/active_record/connection_adapters/nodedb_adapter.rb`
  (`ADVISORY_LOCKS_COLLECTION`, `get_advisory_lock`,
  `release_advisory_lock`)
- No-op stubs landed: PR #30; collection-based lock replaced them
  2026-07-04
