# BUG-004: DROP COLLECTION IF EXISTS broken when collection exists

## Status: OPEN (retested 2026-05-10)

Still reproduces. When the collection exists,
`DROP COLLECTION IF EXISTS name` fails with `ERROR: collection 'if' does not exist`.
When the collection does NOT exist, `IF EXISTS` silently succeeds (partial fix).
Workaround in `nodedb-ruby` `Collection.drop_if_exists` and adapter
`drop_collection(if_exists:)` rescue still required.

## Summary

`DROP COLLECTION IF EXISTS name` fails with `ERROR: collection 'if' does not exist`.
NodeDB parses `IF` as a collection name rather than recognising the `IF EXISTS` clause.

## Environment

- NodeDB version: `0.1.0`
- Client: `psql` (pgwire, port 6432)
- Date: 2026-05-09
- **Re-tested 2026-05-10 (rebuild)**: Still broken. New behaviour: `IF EXISTS` silently succeeds when collection does NOT exist (partial fix), but when collection DOES exist, `IF` is parsed as a collection name → `ERROR: collection 'if' does not exist`.

## Reproduction

```sql
CREATE COLLECTION my_collection;
DROP COLLECTION IF EXISTS my_collection;
-- ERROR:  collection 'if' does not exist

-- Contrast: when collection does NOT exist, IF EXISTS silently succeeds (partial fix):
DROP COLLECTION IF EXISTS nonexistent_xyz;
-- DROP COLLECTION  (no error — this part works)
```

## Expected behaviour

`DROP COLLECTION IF EXISTS name` should drop the collection if it exists and succeed
silently if it does not — matching PostgreSQL's `DROP TABLE IF EXISTS` behaviour.

## Impact

- **Severity**: Minor — workaround available
- Standard migration tooling (`drop_table if_exists: true`) and test cleanup code
  relies on `IF EXISTS` to be idempotent
- Workaround: catch `ActiveRecord::StatementInvalid` with "does not exist" message

## Workaround

```ruby
def drop_collection(name, if_exists: false)
  execute("DROP COLLECTION #{name}")
rescue ActiveRecord::StatementInvalid => e
  raise unless if_exists && e.message.include?("does not exist")
end
```
