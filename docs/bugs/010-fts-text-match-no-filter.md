# BUG-010: text_match() predicate does not filter rows

## Status: OPEN (2026-05-10)

`SELECT … WHERE text_match(col, 'q')` returns every row in the collection
rather than only the matching rows. `bm25_score(col, 'q')` returns NULL for
non-matching rows, so the score is the only signal of an actual match.

## Workaround

`NodeDB::FullTextSearch#fts_search` projects `id, bm25_score(...)` and
filters out rows with a nil/zero score in Ruby. Returns
`[{ "id" => ..., "score" => Float }, ...]`. Look up the full record with
`Model.where("id = ?", id).first`.

GitHub issue: mkhairi/activerecord-nodedb-adapter#12
