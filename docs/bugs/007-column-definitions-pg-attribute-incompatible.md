# BUG-007: pg_attribute query returns wrong/incomplete data; DESCRIBE works

## Status: PARTIAL (retested 2026-05-10)

`ActiveRecord::Base.connection.columns(:t)` now returns plausible column
metadata (names, sql types) rather than raising. However the result still
contains a **duplicate `id` row** for `document_strict` collections, which the
adapter masks via `DESCRIBE`. Example:

```
columns: ["id:text(text)", "id:text(text)", "name:text(text)", "age:integer(integer)"]
```

Adapter workaround (DESCRIBE-based fallback) still required.

## Summary

ActiveRecord's `column_definitions` query uses `pg_attribute` joined with `pg_attrdef`,
`pg_type`, and `pg_collation` plus functions like `format_type()`, `pg_get_expr()`, and
`col_description()`. NodeDB does not fully implement these system catalog joins and
functions, causing schema introspection to return incorrect data (Integer values where
Strings are expected, missing columns, wrong types).

## Environment

- NodeDB version: `0.1.0` / `0.1.1`
- Client: `activerecord-nodedb-adapter` via `pg` Ruby gem
- Date: 2026-05-09

## Reproduction

When ActiveRecord loads the schema for any NodeDB collection, it internally runs:

```sql
SELECT a.attname, format_type(a.atttypid, a.atttypmod),
       pg_get_expr(d.adbin, d.adrelid), a.attnotnull, a.atttypid, a.atttypmod,
       c.collname, col_description(a.attrelid, a.attnum) AS comment,
       '' AS identity, '' as attgenerated
  FROM pg_attribute a
  LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
  LEFT JOIN pg_type t ON a.atttypid = t.oid
  LEFT JOIN pg_collation c ON a.attcollation = c.oid AND a.attcollation <> t.typcollation
 WHERE a.attrelid = '"collection_name"'::regclass
   AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY a.attnum
```

NodeDB returns results where the `column_default` field is an Integer instead of a
String/nil, causing `Regexp#match?` to raise `TypeError: no implicit conversion of
Integer into String`.

After patching `has_default_function?`, the schema loading triggers
`Column#hash` → `name.encoding` where `name` is an Integer, raising:

```
NoMethodError: undefined method 'encoding' for an instance of Integer
```

The root cause: the column query to NodeDB returns mismatched data from system
catalogs that NodeDB doesn't fully implement.

## Expected behaviour

`pg_attribute` joined with `format_type()`, `pg_get_expr()`, and `col_description()`
should return the schema data in the same format PostgreSQL does.

## What works

`DESCRIBE collection_name` returns correct column info:

```
       field       |        type        | nullable 
-------------------+--------------------+----------
 id                | TEXT               | false
 ts                | TIMESTAMP TIME_KEY | true
 host              | VARCHAR            | true
 val               | FLOAT              | true
```

Direct `pg_attribute` query (without joins/functions) also works partially:

```sql
SELECT a.attname, a.atttypid, a.attnum, a.attnotnull
  FROM pg_attribute a
 WHERE a.attrelid = 'collection'::regclass AND a.attnum > 0
```

But this is missing the `id` column and metadata columns.

## Impact

- **Severity**: High — breaks `Model.where(...).to_a` and any ActiveRecord query
  that triggers schema loading (which is almost all queries)
- Schema introspection (`columns`, `column_definitions`) always broken

## Workaround (activerecord-nodedb-adapter)

Override `column_definitions` to use `DESCRIBE collection_name` and map NodeDB
type names to PostgreSQL type strings and OIDs:

```ruby
def column_definitions(table_name)
  result = query("DESCRIBE #{table_name}", "SCHEMA")
  result.reject { |row| row[0].to_s.start_with?("__") }.map do |row|
    field_name  = row[0].to_s
    nodedb_type = row[1].to_s
    nullable    = row[2].to_s == "true"
    pg_type, oid = NODEDB_TYPE_MAP[nodedb_type.upcase.split("(").first.strip] || ["text", 25]
    [field_name, pg_type, nil, !nullable, oid, -1, nil, nil, "", ""]
  end
end
```

Also override `has_default_function?` to guard against non-String column defaults.

## Related

- Similar issues exist in other alternative-PG-wire databases (CockroachDB, YugabyteDB)
  that implement pg_attribute incompletely.
