# Full-Text Search Engine

NodeDB FTS provides BMW BM25 ranking, 27-language support, CJK bigrams, fuzzy matching,
and hybrid vector+FTS fusion.

## Setup

```ruby
# Model (FTS is available on any collection — no special engine needed)
class Article < ApplicationRecord
  include NodeDB::FullTextSearch
  fts_column :body, language: "english"
  fts_column :title, language: "english"  # multiple FTS columns supported
end
```

## Queries

```ruby
# Basic FTS search
Article.fts_search("machine learning", limit: 20)

# Explicit column
Article.fts_search("deep learning", column: :title, limit: 5)

# Fuzzy matching (handles typos)
Article.fts_search("nural networks", fuzzy: true, limit: 10)
```

## SQL emitted

```sql
SEARCH articles USING FTS(body, 'machine learning', 20)
SEARCH articles USING FTS(title, 'deep learning', 5)
SEARCH articles USING FTS(body, 'nural networks', 10 FUZZY)
```

## Language support

Pass any NodeDB-supported language to `fts_column`:
`english`, `spanish`, `french`, `german`, `portuguese`, `chinese`, `japanese`, `korean`,
and 19 more. See NodeDB docs for the full list.
