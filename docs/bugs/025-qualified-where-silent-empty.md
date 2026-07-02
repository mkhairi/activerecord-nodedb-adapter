# BUG-025: table-qualified column refs in WHERE silently match zero rows (except TEXT PK equality)

## Status: OPEN (discovered 2026-07-02 against upstream `3a06321e`)

A `WHERE` predicate referencing a column with table qualification
(`"table"."column"`) matches **zero rows silently** — no error — unless
it is a TEXT primary-key equality (point-lookup fast path). Unqualified
predicates on the same data work.

ActiveRecord qualifies every hash-condition it generates, so all
idiomatic AR queries are broken: `Model.where(name: "x")` finds
nothing, `.count` with conditions returns 0, uniqueness validations
pass vacuously. The adapter's engine concerns (KV, FTS, graph, ...)
build raw unqualified SQL, which is why the suite and sample app never
tripped it — and why emptiness assertions in the suite pass vacuously.

## Reproduction (psql, pgwire 6432)

```sql
CREATE COLLECTION q (id TEXT PRIMARY KEY, name TEXT, valid_from TIMESTAMP) ENGINE = document_strict;
INSERT INTO q (id, name, valid_from) VALUES ('a', 'alpha', '2026-07-02 13:00:00');

SELECT id FROM q WHERE name = 'alpha';                             -- 1 row
SELECT id FROM q WHERE "q"."name" = 'alpha';                       -- 0 rows (wrong)
SELECT id FROM q WHERE "q"."valid_from" <= '2026-07-02 14:00:00';  -- 0 rows (wrong)
SELECT id FROM q WHERE "q"."id" <= 'z';                            -- 0 rows (wrong)
SELECT id FROM q WHERE "q"."id" = 'a';                             -- 1 row (PK fast path)
```

## Expected

Qualified and unqualified refs resolve identically for single-table
queries. If unsupported, error loudly (older builds did) instead of
matching nothing.

## Impact

- Every AR hash-condition on a non-PK column silently returns empty.
- Blocks app-level libraries wholesale — found evaluating
  kufu/activerecord-bitemporal, whose implicit scopes
  (`"t"."valid_from" <= ... AND "t"."valid_to" > ...`) match nothing.
- Suite needs a regression spec asserting a qualified non-PK `where`
  finds rows (currently passes vacuously on emptiness assertions).

## Workaround (candidate, not shipped)

Adapter-side rewrite stripping `"<table_name>".` qualification from
single-table SELECT/UPDATE/DELETE before dispatch (safe when no
JOIN/alias present). Prototype as `fix/dequalify-single-table-where`.

## Tracking

GitHub issue: mkhairi/activerecord-nodedb-adapter#74
