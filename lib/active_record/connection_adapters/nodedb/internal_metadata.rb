require "active_record/internal_metadata"

module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      # NodeDB-aware replacement for ActiveRecord::InternalMetadata.
      #
      # Stores the lookup key in the NodeDB-mandatory `id` column rather than
      # `key`. document_strict collections insist on `id` as the PK; a custom
      # `key TEXT PRIMARY KEY` triggers a duplicate-empty-id collision on the
      # second INSERT (NodeDB upstream quirk).
      class InternalMetadata < ::ActiveRecord::InternalMetadata
        def create_table
          return unless enabled?

          @pool.with_connection do |connection|
            unless connection.collections.include?(table_name)
              connection.execute(
                "CREATE COLLECTION #{table_name} (" \
                "id TEXT PRIMARY KEY, " \
                "value TEXT, " \
                "created_at TIMESTAMP, " \
                "updated_at TIMESTAMP" \
                ") WITH (engine='document_strict')"
              )
            end
          end
        end

        def drop_table
          return unless enabled?

          @pool.with_connection do |connection|
            connection.drop_collection(table_name, if_exists: true)
          end
        end

        def []=(key, value)
          return unless enabled?

          @pool.with_connection do |connection|
            existing = connection.execute(
              "SELECT id FROM #{table_name} WHERE id = #{connection.quote(key.to_s)} LIMIT 1"
            ).first

            now = Time.now.utc.iso8601
            if existing
              connection.execute(
                "UPDATE #{table_name} SET " \
                "value = #{connection.quote(value.to_s)}, " \
                "updated_at = #{connection.quote(now)} " \
                "WHERE id = #{connection.quote(key.to_s)}"
              )
            else
              connection.execute(
                "INSERT INTO #{table_name} (id, value, created_at, updated_at) VALUES (" \
                "#{connection.quote(key.to_s)}, " \
                "#{connection.quote(value.to_s)}, " \
                "#{connection.quote(now)}, " \
                "#{connection.quote(now)})"
              )
            end
          end
        end

        def [](key)
          return unless enabled?

          @pool.with_connection do |connection|
            # A point-lookup (WHERE id=) projects logical columns on both
            # transports, so the `value` column comes back directly.
            row = connection.execute(
              "SELECT value FROM #{table_name} WHERE id = #{connection.quote(key.to_s)} LIMIT 1"
            ).first
            row && row["value"]
          end
        end

        def delete_all_entries
          @pool.with_connection do |connection|
            connection.execute("DELETE FROM #{table_name}")
          end
        end

        def count
          @pool.with_connection do |connection|
            connection.execute("SELECT id FROM #{table_name}").to_a.size
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
