# BUG-016: document_strict second INSERT collides on empty `id` when PRIMARY KEY is on a non-`id` column

## Status: RESOLVED (retested 2026-07-02 against upstream `3a06321e`)

Fixed upstream in commit 967dff93. The doc id
is now derived from the user-declared PRIMARY KEY column instead of
guessed `id`/`document_id`/`key` names. Verified: multiple INSERTs
with a non-`id` PK round-trip, and a genuine duplicate is rejected
naming the real key value.

The `Nodedb::SchemaMigration` / `Nodedb::InternalMetadata` id-column
mapping (PR #24) still ships — it works correctly either way;
unwinding it is optional cleanup, not a correctness fix.

### Earlier history (OPEN, 2026-05-10)

A `WITH (engine='document_strict')` collection that declares its
PRIMARY KEY on any column other than `id` accepts the first INSERT
correctly but rejects the second with:

```
ERROR:  constraint violation: unique: duplicate key value '' violates primary-key uniqueness on '<table>'
```

The "duplicate empty key" is the synthetic NodeDB-internal `id` field,
which `document_strict` apparently auto-allocates and fails to
populate uniquely after the first row.

## Reproduction (psql)

```sql
CREATE COLLECTION sm (version TEXT PRIMARY KEY) WITH (engine='document_strict');
INSERT INTO sm (version) VALUES ('20260101000000');  -- OK
INSERT INTO sm (version) VALUES ('20260102000000');
-- ERROR: constraint violation: unique: duplicate key value '' on 'sm'
```

A schema with `id TEXT PRIMARY KEY` (the user-facing PK living in the
built-in `id` column) round-trips both inserts correctly.

## Expected

`PRIMARY KEY` on any user-declared column should round-trip multiple
INSERTs. Either the synthetic internal `id` should auto-generate
unique values, or `document_strict` should require the user PK to live
in `id` and reject the schema at DDL time (rather than failing on the
second INSERT).

## Workaround in this adapter

`Nodedb::SchemaMigration` and `Nodedb::InternalMetadata` declare the
user-facing key in the mandatory `id` column directly:

```sql
CREATE COLLECTION schema_migrations (id TEXT PRIMARY KEY)
  WITH (engine='document_strict')
```

then map the lookup value (migration version, metadata key) to / from
the `id` column at the AR layer. See PR #24.

User-facing collections in the sample app that follow this convention
work fine; only NodeDB's parser-level acceptance of "non-id PK" is
misleading.

## References

- GitHub issue: mkhairi/activerecord-nodedb-adapter#34
- Workaround landed: PR #24
