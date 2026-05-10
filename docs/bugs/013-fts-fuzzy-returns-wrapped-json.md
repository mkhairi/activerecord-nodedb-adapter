# BUG-013: FTS fuzzy mode returns wrapped JSON instead of flat columns

## Status: OPEN (2026-05-10)

When `text_match()` and `bm25_score()` are called with `{ fuzzy: true }`,
NodeDB **ignores the SELECT projection** and returns each row as a single
`result` column containing JSON (`{"data": {...}, "id": "..."}`). Plain
non-fuzzy mode returns flat columns as projected.

## Reproduction

```sql
-- Non-fuzzy: flat projection works.
SELECT id, bm25_score(body, 'neural') AS s
FROM posts WHERE text_match(body, 'neural') LIMIT 1;
--                  id                  |  s
-- --------------------------------------+-----
--  1380d384-...                         | 0.0

-- Fuzzy: projection ignored, JSON wrapper returned.
SELECT id, bm25_score(body, 'nural', { fuzzy: true, distance: 2 }) AS s
FROM posts WHERE text_match(body, 'nural', { fuzzy: true, distance: 2 }) LIMIT 1;
--                                  result
-- --------------------------------------------------------------------
--  {"data":{"body":"...","id":"...","s":0.0,"title":"..."},"id":"..."}
```

## Workaround

`NodeDB::FullTextSearch#fts_search` now unwraps single-column `result` rows
by JSON-parsing and pulling fields out of `data.*`. Same return shape
either way.

GitHub issue: filed alongside this commit.
