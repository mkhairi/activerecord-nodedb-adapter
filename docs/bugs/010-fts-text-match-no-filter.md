# BUG-010: text_match() predicate does not filter rows

## Status: RESOLVED upstream — post-v0.2.1 build (retested 2026-05-18)

`SELECT id FROM t WHERE text_match(col, 'q')` now returns **only** the
matching rows. Verified on the 2026-05-18 upstream build (commit
`a178aa5b`) both with and without a `CREATE FULLTEXT INDEX`.

Adapter workaround **retired** (`activerecord-nodedb-adapter`
0.1.0.alpha.6): `NodeDB::FullTextSearch#fts_search` no longer projects
`bm25_score` or drops nil-score rows client-side — it issues
`SELECT id … WHERE text_match(col, q)` and trusts the server-side
filter. `bm25_score()` was unusable for this anyway (returned `0.0`
for matches / `nil` for non-matches with no IDF differential on small
corpora). Return shape changed from
`[{ "id" =>, "score" => Float }]` to `[{ "id" => }]`.

Note: NodeDB also **removed the standalone `fts` engine** on this build.
FTS is now a `document_strict` collection plus a
`CREATE FULLTEXT INDEX <name> ON <coll> (<col>)`. The adapter's
`create_fts(name, fulltext: […])` helper builds both; legacy
`engine: :fts` maps to `document_strict`.

### Earlier history (OPEN, 2026-05-10)

`SELECT … WHERE text_match(col, 'q')` returns every row in the collection
rather than only the matching rows. `bm25_score(col, 'q')` returns NULL for
non-matching rows, so the score is the only signal of an actual match.

## Workaround

`NodeDB::FullTextSearch#fts_search` projects `id, bm25_score(...)` and
filters out rows with a nil/zero score in Ruby. Returns
`[{ "id" => ..., "score" => Float }, ...]`. Look up the full record with
`Model.where("id = ?", id).first`.

GitHub issue: mkhairi/activerecord-nodedb-adapter#12
