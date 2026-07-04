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

        # Insert-first upsert: the PK uniqueness constraint is the
        # existence check. A read-then-branch would both race and prime
        # BUG-033's poisoned negative cache (a `WHERE id =` miss makes
        # that key's point-lookups return empty for the rest of the
        # session — exactly AR's miss -> insert -> re-read migrator
        # flow on 'environment').
        DUPLICATE_KEY_RE = /primary-key uniqueness|duplicate key/i

        def []=(key, value)
          return unless enabled?

          @pool.with_connection do |connection|
            now = Time.now.utc.iso8601
            begin
              connection.execute(
                "INSERT INTO #{table_name} (id, value, created_at, updated_at) VALUES (" \
                "#{connection.quote(key.to_s)}, " \
                "#{connection.quote(value.to_s)}, " \
                "#{connection.quote(now)}, " \
                "#{connection.quote(now)})"
              )
            rescue ActiveRecord::StatementInvalid => e
              raise unless e.message.match?(DUPLICATE_KEY_RE)

              connection.execute(
                "UPDATE #{table_name} SET " \
                "value = #{connection.quote(value.to_s)}, " \
                "updated_at = #{connection.quote(now)} " \
                "WHERE id = #{connection.quote(key.to_s)}"
              )
            end
          end
        end

        # Scan + client-side filter instead of `WHERE id = <key>`: the
        # bare PK-equality shape is BUG-033's poisoned read, and this
        # collection holds a handful of rows at most.
        def [](key)
          return unless enabled?

          @pool.with_connection do |connection|
            row = connection.execute("SELECT id, value FROM #{table_name}")
                            .find { |r| r["id"] == key.to_s }
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
