require "active_record/tasks/postgresql_database_tasks"

module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      # Database tasks for `bin/rails db:*` (create, drop, schema dump, ...).
      #
      # The adapter does not manage databases: `db:create` and `db:drop` are
      # no-ops, and the configured name must already exist, or the connection
      # fails. The daemon bootstraps a database named `default`. Structure
      # dump/load go through `db/schema.rb` via our SchemaDumper (#26).
      #
      # PG's task class handles `db:migrate`, `db:rollback`,
      # `db:migrate:status`, `db:seed`, charset, etc. correctly already.
      # We subclass to no-op the database-creation pieces and keep the rest.
      class DatabaseTasks < ActiveRecord::Tasks::PostgreSQLDatabaseTasks
        def create(*)
          # Succeed without creating anything, so `db:create` in CI and boot
          # scripts does not abort.
          $stdout.puts "[nodedb] db:create — singleton database; skipping CREATE."
        end

        def drop(*)
          $stdout.puts "[nodedb] db:drop — singleton database; skipping DROP."
        end

        def purge(*)
          # `db:reset` / `db:test:prepare` call this. Iterate collections
          # and DROP each one (NodeDB's analogue of TRUNCATE TABLE for
          # cleanup). Skips schema_migrations / ar_internal_metadata so
          # AR's tracking survives.
          connection.collections.each do |name|
            next if %w[schema_migrations ar_internal_metadata].include?(name)
            connection.drop_collection(name, if_exists: true)
          end
        end

        def charset
          "UTF8"
        end

        def collation
          "C"
        end

        # Structure dump uses our Nodedb::SchemaDumper — same engine-aware
        # output as `rails db:schema:dump`.
        def structure_dump(filename, extra_flags = nil)
          File.open(filename, "w:utf-8") do |io|
            ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, io)
          end
        end

        def structure_load(filename, extra_flags = nil)
          load(filename)
        end
      end
    end
  end
end
