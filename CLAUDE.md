# activerecord-nodedb-adapter — project rules

Workspace-wide rules (branch/PR workflow, upstream-bug lifecycle,
versioning, release checklist, "what to never do") live in the monorepo
root: `../../CLAUDE.md`. **Read that first.** Anything below adds or
overrides for this gem only.

## Project

ActiveRecord adapter for NodeDB. Extends
`ActiveRecord::ConnectionAdapters::PostgreSQLAdapter` and adds NodeDB
engine-aware DDL/DML, type casters, model concerns
(`NodeDB::Vector`, `Graph`, `Timeseries`, `Spatial`, `KV`,
`FullTextSearch`, `Bitemporal`), collection-based advisory locks
(migration mutex + `with_advisory_lock` block API), and NodeDB-aware
`SchemaMigration` / `InternalMetadata` so `rails db:migrate` works.

Sits on top of `nodedb-ruby` (path-checked-out locally; github: gem in
downstream apps).

Status: **alpha** (`0.1.0.alpha.N`).

## Tests

```bash
bundle exec rspec
```

Requires a live NodeDB on `localhost:6432` (and `:6433` for the native
transport specs); the suite targets the **default `nodedb` database**
by convention (CREATE DATABASE'd databases were unusable for most of
the alpha, since fixed upstream; `NODEDB_URL` overrides). Must stay 0 failures, 0 pending before any PR
merges. New behaviour requires a spec; new NodeDB workaround requires
a spec that asserts the workaround's effect (not just "doesn't
crash").

Bug records live on the issue tracker (`[upstream:NodeDB] BUG-NNN` —
see the root CLAUDE.md lifecycle). `docs/bugs/` is gitignored local
scratch; `docs/KNOWN_ISSUES.md` is the user-facing rollup.

For a full-stack smoke that touches every engine end-to-end, run the
sample app's feature smoke. The sample app lives at
[mkhairi/nodedb-on-rails](https://github.com/mkhairi/nodedb-on-rails);
clone alongside this repo and run:

```bash
cd ../nodedb-on-rails && bundle exec ruby bin/rails runner scripts/feature_smoke.rb
```

## Release checklist additions

Standard alpha release flow lives in `../../CLAUDE.md`. The version
file for this gem is `lib/activerecord_nodedb_adapter/version.rb`.

## License

BSD 2-Clause. See `LICENSE.md`.
