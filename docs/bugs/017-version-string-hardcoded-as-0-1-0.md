# BUG-017: server_version stuck at "NodeDB 0.1.0" after upstream bumped to 0.2.0

## Status: RESOLVED upstream — NodeDB v0.2.1 (retested 2026-05-15)

Merged in upstream PR #114. Every wire surface now sources from
`crate::version::VERSION` (was `CARGO_PKG_VERSION` per the original fix;
upstream maintainer refactored further). Verified:

```sql
SHOW server_version;
-- NodeDB 0.2.1
```

### Earlier history (OPEN, 2026-05-15)

NodeDB's workspace `Cargo.toml` declares `version = "0.2.0"` but four
pgwire / RESP / sync call sites in `nodedb/src/control/server/**`
hardcode the literal string `"0.1.0"`. Result: pgwire clients always see
`NodeDB 0.1.0` regardless of which release the binary was built from.

## Reproduction (psql)

```sql
SHOW server_version;
-- NodeDB 0.1.0
```

Cross-check the binary actually came from 0.2.0 source:

```bash
md5sum /proc/$(pgrep -x nodedb)/exe nodedb/target/release/nodedb
# both hashes match — same binary
grep '^version' nodedb/Cargo.toml
# version = "0.2.0"
```

## Affected source locations

| File | Line | Symbol |
| ---- | ---- | ------ |
| `nodedb/src/control/server/pgwire/factory.rs` | 152 | startup params `server_version` |
| `nodedb/src/control/server/pgwire/handler/session_cmds.rs` | 238 | `SHOW server_version` handler |
| `nodedb/src/control/server/resp/handler.rs` | 418 | RESP `INFO` command |
| `nodedb/src/control/server/sync/dlq.rs` | 409 | sync DLQ `client_version` field |

`nodedb/src/control/server/native/handshake.rs:90` uses
`env!("CARGO_PKG_VERSION")` correctly and reports the right number; only
the pgwire / RESP / sync paths drift.

## Expected

All four hardcoded strings should source from
`env!("CARGO_PKG_VERSION")` (or the workspace equivalent) so the wire
version matches the binary's source tree.

## Impact

- `SHOW server_version` reports stale info; the
  `activerecord-nodedb-adapter`'s `nodedb_version` helper passes it
  straight through.
- Pgwire startup parameter `server_version` carries the same stale
  string; libpq-aware clients caching it get wrong info.
- Confuses anyone trying to diagnose whether they're running 0.1.0 vs
  0.2.0 features.

## Adapter workaround

None on the adapter side — the value is whatever the server says.
Sample app's `/server_info` page displays it as-is, which made the
discrepancy visible.

## Upstream fix sketch

```rust
// pgwire/factory.rs
params.server_version = format!(
    "NodeDB {} (pgwire {})",
    env!("CARGO_PKG_VERSION"),
    env!("CARGO_PKG_VERSION")
);

// pgwire/handler/session_cmds.rs
"server_version" => Some(format!("NodeDB {}", env!("CARGO_PKG_VERSION"))),

// resp/handler.rs
write!(buf, "# Server\r\nnodedb_version:{}\r\n…", env!("CARGO_PKG_VERSION"))?;

// sync/dlq.rs
client_version: env!("CARGO_PKG_VERSION").into(),
```

Four lines per call site; trivial PR upstream.
