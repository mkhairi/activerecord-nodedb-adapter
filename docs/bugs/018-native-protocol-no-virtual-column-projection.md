# BUG-018: native protocol returns document-backed rows as a raw `{data, id}` blob (no virtual-column projection)

## Status: OPEN (2026-05-16) — NodeDB v0.2.1, **native binary protocol only** (port 6433)

pgwire (port 6432) is **unaffected** — it projects the logical columns
server-side. This is a native-vs-pgwire behavioural divergence in the
NodeDB server, surfaced by the adapter's `transport: native` option
(shipped in activerecord-nodedb-adapter 0.1.0.alpha.4, PR #44).

## Schema-tracking impact — native + Rails migrations is BLOCKED (2026-05-16)

`schema_migrations` and `ar_internal_metadata` are `document_strict`
collections (BUG-016 stores the version/key in the mandatory `id`
column). Over native, reading them back hits this bug:

```
INSERT id='001','002' INTO schema_migrations (document_strict)
SELECT id FROM schema_migrations  ->  columns ["data","id"]
                                      rows [["{\"id\":\"001\"}","00000003"], …]
SchemaMigration#versions          ->  ["00000003","00000004"]   # internal
                                      # surrogates, NOT "001"/"002"
```

`SchemaMigration#versions` / `InternalMetadata#[]` therefore never
return the real values, so AR's migrator believes nothing is applied,
re-runs `001`, and aborts with `collection 'articles' already exists`.

**~~Net: `db:migrate` / `db:schema:load` do not work over `transport:
native`~~ — RESOLVED for schema-tracking, see "Key nuance" below.**
This was the original diagnosis; it held until the point-lookup-vs-scan
distinction was found. A separate, transport-independent
defect was fixed along the way: AR's `assume_migrated_upto_version`
hardcodes `INSERT INTO schema_migrations (version) …`, but
`schema_migrations` is a `document_strict` collection with only an `id`
field and NodeDB enforces that strict schema on **both pgwire and
native** — so the `db:schema:load` / `db:prepare` path raised
`unknown field 'version' not present in strict schema` on pgwire too
(`bin/setup` sidesteps it via `create_version`→`id`). The adapter now
always routes version inserts through `SchemaMigration#create_version`
(`id` column).

### Key nuance: point-lookups DO project over native (2026-05-16)

The blob behaviour is **scan-shaped**, not blanket:

| Query shape (document_strict, native)        | Result |
| -------------------------------------------- | ------ |
| `SELECT * FROM t` (unfiltered full scan)     | `{data, id}` blob — declared columns absent |
| `SELECT * FROM t WHERE id = '<pk>'` (point)  | **projected columns** (real `value`, `lat`, …) |
| `SELECT data FROM t`                          | empty (native ignores the literal `data` projection) |

So **schema-tracking is now unblocked on native** without an upstream
fix:

- `InternalMetadata#[]` already does `WHERE id = <key>` → projects
  natively, no change needed.
- `SchemaMigration#versions` is an unfiltered scan → over native it now
  `SELECT *`s and JSON-parses the stored version out of the `data` blob
  (`WHERE`/`INSERT`/`DELETE` on the logical `id` resolve natively, so
  only this read path needs the unpack).

Verified both transports: `versions == ["1".."6"]`,
`needs_migration? == false`, `pending == []`, `internal_metadata[:environment] == "development"`.
`db:migrate` / `db:schema:load` / dev `check_pending!` now work over
`transport: native`. pgwire unchanged (21/21); AR suite 32/0.

The remaining native gap is **runtime full-scan reads on
document-backed engines** (spatial / FTS / vector raw `SELECT col …`),
still the upstream parity target below.

### Practical guidance until upstream parity

- Run `db:migrate` / `bin/setup` over **pgwire** (port 6432); run the
  app over **native** (6433) for the engines that already pass
  (connection, document model CRUD, timeseries, graph).
- Or stay on pgwire end-to-end.
- Full native parity (incl. migrations) needs either the upstream fix
  below, or an adapter rework moving schema-tracking off
  `document_strict` onto an engine that *does* project over native
  (the `kv` engine projects `["key","value"]` natively — candidate).

## Summary

For collections whose rows are stored as a document (`document_strict`,
and the default document engine used by `create_collection` without an
`engine:`), the **native** protocol returns every `SELECT` as two
physical columns:

```
columns = ["data", "id"]
data    = <the whole row as a JSON string>
id      = <internal hex surrogate, e.g. "0000000e">
```

The **pgwire** protocol, given the identical collection and query,
expands the declared/logical fields into real result columns
(`lat`, `lon`, `title`, `bm25_score`, `distance`, …).

The adapter's *model* read path survives because the NodeDB-aware column
mapping unpacks the document; but **raw `connection.execute` / engine
helper SQL that expects projected columns gets the blob instead**, so
spatial, FTS and vector reads return empty/nil over native.

KV (`engine='kv'`) is a separate symptom — its columns *do* project
(`["key","value"]`), but the KV read helper still raises
`KeyError: "value"` over native, so it is tracked in the table below as a
distinct native-read shape mismatch, not the blob issue.

## Reproduction

Same NodeDB instance, same `nodedb` database, same collections (seeded by
the `nodedb-on-rails` sample app), only the transport differs.

```ruby
# locations is engine=document_strict (lat FLOAT, lon FLOAT, name TEXT)

# pgwire (6432)
c.execute("SELECT id, lat, lon FROM locations LIMIT 1").to_a
# => [{"id"=>"seed_kl", "lat"=>3.139, "lon"=>101.6869}]

# native (6433)
r = c.execute("SELECT * FROM locations LIMIT 1")
r.fields           # => ["data", "id"]
r.values.first     # => ["{\"id\":\"seed_kl\",\"lat\":3.139,\"lon\":101.6869,\"name\":\"Kuala Lumpur\"}", "0000000e"]
r.to_a.first["lat"] # => nil   (no "lat" column exists in the native result)
```

Full reproduction = run the sample app's full-engine smoke over each
transport (`scripts/feature_smoke.rb`):

```bash
# pgwire baseline
bundle exec ruby bin/rails runner scripts/feature_smoke.rb
#   ok: 21  total: 21

# native (establish_connection adapter:"nodedb", transport:"native", port:6433)
#   ok: 14  fail: 3  error: 2  total: 19
```

## Transport parity matrix (track this each NodeDB release)

NodeDB v0.2.1. PASS = functionally equivalent to pgwire. Update the
`native` column on every retest; the goal is full parity.

| Engine / area              | pgwire (6432) | native (6433) | Native gap (root cause)                                              |
| -------------------------- | ------------- | ------------- | -------------------------------------------------------------------- |
| Connection / `active?`        | PASS       | PASS          | —                                                                    |
| Schema tracking / migrations  | PASS       | PASS          | point-lookups project; shim normalises the scan blob                 |
| Collections listing           | PASS       | PASS          | —                                                                    |
| Document CRUD (model)         | PASS       | PASS          | —                                                                    |
| Doc collection reads (`.all`/`.first`/scopes/index) | PASS | PASS | **fixed**: `NativePGCompat::Result` normalises both native shapes |
| Timeseries insert/bucket      | PASS       | PASS          | —                                                                    |
| Graph edge/traverse/algo      | PASS       | PASS          | —                                                                    |
| Spatial roundtrip             | PASS       | PASS          | **fixed** by the result normaliser                                   |
| `COUNT(*)` / aggregates       | PASS       | **FAIL**      | native returns the empty-`result` form → count `0` (upstream)        |
| KV set/get/exists/delete      | PASS       | **FAIL**      | KV read helper shape mismatch (`KeyError "value"`)                    |
| FTS search / fuzzy            | PASS       | **FAIL**      | `text_match`/`bm25_score` native shape not normalisable client-side  |
| Vector search                 | PASS       | **ERR**       | vector-search native shape; `distance` absent                        |
| **Totals (feature_smoke)**    | **21/21**  | **15 / 19**   |                                                                      |

## Expected

The native protocol should project a document collection's logical
columns into the result set the same way pgwire does (i.e. `SELECT lat,
lon FROM locations` yields `lat`/`lon` columns, not a single `data`
JSON string). Result-set column semantics should not depend on the
transport.

## Impact

- `transport: native` is **not yet at functional parity** with pgwire
  for KV / spatial / FTS / vector reads. It IS solid for connection,
  DDL, document model CRUD, timeseries and graph.
- Any code doing raw `connection.execute("SELECT col …")` on a
  document-backed collection over native gets the JSON blob instead of
  the column.

## Adapter workaround (SHIPPED)

`NativePGCompat::Result` now normalises the two non-projected native
document shapes back into real columns (native-only path; pgwire never
produces these, so it is untouched):

- **A — `["data","id"]`**: one row per record, `data` = the row as a
  JSON string, `id` = internal surrogate. Parse each `data`, emit the
  union of JSON keys as columns.
- **B — `["result"]`**: a single cell whose value is a JSON array of row
  objects; `"[]"` for an empty collection. Parse it; an empty array
  becomes a genuinely empty result (no phantom row → no
  `MissingAttributeError`), a populated array expands like A.

Effect: model collection reads (`.all` / `.first` / scopes / index
pages), document_strict spatial round-trips, and schema-tracking scans
all work over `transport: native`. Verified: sample-app `/articles`
renders 200 over native; `feature_smoke` native 15/19; pgwire 21/21
(unaffected); adapter rspec 32/0.

Still **not** client-side fixable (upstream BUG-018, #45):

- `COUNT(*)` / aggregates — native returns the empty-`result` form
  regardless of row count, so counts read as `0`.
- FTS (`text_match` / `bm25_score`) and vector search — distinct native
  result shapes with computed columns that aren't present to reconstruct.

The correct long-term fix is still server-side: native should project
logical columns like pgwire. Until then the shim covers the common
document read paths; aggregates/FTS/vector need pgwire.

## Upstream fix sketch

The native result encoder for document-backed engines should run the
same projection/column-materialisation step the pgwire result path
already runs, rather than emitting the raw storage tuple `(data, id)`.
Parity target: identical `columns` + row values for the same SQL
regardless of transport.

GitHub issue: mkhairi/activerecord-nodedb-adapter#45
