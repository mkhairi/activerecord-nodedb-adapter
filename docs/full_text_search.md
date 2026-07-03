# Full-Text Search Engine

NodeDB FTS provides BM25 ranking, 27-language support, CJK bigrams, and
fuzzy matching. Since the 2026-05-18 upstream build there is no
standalone `fts` engine — FTS lives on a `document_strict` collection
plus a `CREATE FULLTEXT INDEX`.

## Setup

```ruby
# Migration — create_fts builds the document_strict collection AND the
# fulltext index in one step
create_fts :posts, fulltext: [:body] do |t|
  t.text :id, primary_key: true
  t.text :title
  t.text :body
end

# Model
class Post < ApplicationRecord
  include NodeDB::FullTextSearch
  fts_column :body, language: "english"
  fts_column :title, language: "english"  # multiple FTS columns supported
end
```

(Legacy `create_collection :posts, engine: :fts` still works — it maps
to `document_strict`; you must add the fulltext index yourself.)

## Queries

```ruby
Post.fts_search("machine learning", limit: 20)
# => [{ "id" => "..." }, ...]

Post.fts_search("deep learning", column: :title, limit: 5)
Post.fts_search("nural networks", fuzzy: true, limit: 10)   # typo-tolerant
```

`fts_search` returns an Array of `{ "id" => ... }` hashes — NodeDB
filters server-side via the `text_match()` predicate and the helper
projects only `id`. Load full records with a follow-up query:

```ruby
ids = Post.fts_search("machine learning").map { |r| r["id"] }
Post.where(id: ids)
```

## SQL emitted

```sql
SELECT id FROM posts WHERE text_match(body, 'machine learning') LIMIT 20
SELECT id FROM posts WHERE text_match(title, 'deep learning') LIMIT 5
SELECT id FROM posts WHERE text_match(body, 'nural networks', { fuzzy: true, distance: 2 }) LIMIT 10
```

## Language support

Pass any NodeDB-supported language to `fts_column`: `english`,
`spanish`, `french`, `german`, `portuguese`, `chinese`, `japanese`,
`korean`, and 19 more. See the NodeDB docs for the full list.
