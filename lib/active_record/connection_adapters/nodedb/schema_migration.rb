require "active_record/schema_migration"

module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      # NodeDB-aware replacement for ActiveRecord::SchemaMigration.
      #
      # Stores the version string in the NodeDB-mandatory `id` column rather
      # than `version` — document_strict collections require `id` to be the
      # PK; declaring `version TEXT PRIMARY KEY` triggers a duplicate-empty-id
      # collision on the second INSERT (NodeDB upstream quirk).
      #
      # Reads return the value as `version` to match AR's contract.
      class SchemaMigration < ::ActiveRecord::SchemaMigration
        def create_table
          @pool.with_connection do |connection|
            unless connection.collections.include?(table_name)
              connection.execute(
                "CREATE COLLECTION #{table_name} (id TEXT PRIMARY KEY) " \
                "WITH (engine='document_strict')"
              )
            end
          end
        end

        def drop_table
          @pool.with_connection do |connection|
            connection.drop_collection(table_name, if_exists: true)
          end
        end

        # Full scans project logical columns on both transports, so
        # `SELECT id` yields the stored version everywhere.
        def versions
          @pool.with_connection do |connection|
            connection.execute("SELECT id FROM #{table_name} ORDER BY id ASC").to_a.map { |r| r["id"] }
          end
        end

        def integer_versions
          versions.map(&:to_i)
        end

        def count
          @pool.with_connection do |connection|
            connection.execute("SELECT id FROM #{table_name}").to_a.size
          end
        end

        def create_version(version)
          @pool.with_connection do |connection|
            connection.execute(
              "INSERT INTO #{table_name} (id) VALUES (#{connection.quote(version.to_s)})"
            )
          end
        end

        def delete_version(version)
          # AR's Migrator goes through `version.to_i.to_s` before calling
          # us, which strips leading zeros from filename-style versions
          # ("006" -> "6"). Match both literal and zero-padded forms so
          # rollbacks work regardless of how the value was inserted.
          @pool.with_connection do |connection|
            literal = connection.quote(version.to_s)
            integer = connection.quote(version.to_i.to_s)
            clauses = ["id = #{literal}", "id = #{integer}"]
            if version.to_s.match?(/\A\d+\z/)
              clauses << "id = #{connection.quote(format('%03d', version.to_i))}"
            end
            connection.execute(
              "DELETE FROM #{table_name} WHERE #{clauses.uniq.join(' OR ')}"
            )
          end
        end

        def delete_all_versions
          @pool.with_connection do |connection|
            connection.execute("DELETE FROM #{table_name}")
          end
        end

        def table_exists?
          @pool.with_connection do |connection|
            connection.collections.include?(table_name)
          end
        end
      end
    end
  end
end
