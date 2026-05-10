# Key-Value Engine

NodeDB KV provides O(1) lookups, TTL, sorted indexes, and SQL queryability.

## Setup

```ruby
# Migration
create_collection :kv_sessions, engine: :kv

# Model
class KvSession < ApplicationRecord
  include NodeDB::KV
  self.primary_key = :key
  self.table_name  = "kv_sessions"
end
```

## Operations

```ruby
# Set a value (with optional TTL in seconds)
KvSession.kv_set("sess_abc", "user_id:42", ttl: 3600)

# Get a value
KvSession.kv_get("sess_abc")  # => "user_id:42"

# Check existence
KvSession.kv_exists?("sess_abc")  # => true

# Delete
KvSession.kv_delete("sess_abc")

# Standard AR queries still work (KV is SQL-queryable)
KvSession.where("key LIKE 'sess_%'").count
```

## SQL emitted

```sql
INSERT INTO kv_sessions (key, value) VALUES ('sess_abc', 'user_id:42')
UPDATE kv_sessions SET ttl = 3600 WHERE key = 'sess_abc'
SELECT * FROM kv_sessions WHERE key = 'sess_abc'
DELETE FROM kv_sessions WHERE key = 'sess_abc'
```
