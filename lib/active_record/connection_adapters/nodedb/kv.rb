module NodeDB
  # Include in a model backed by a NodeDB KV collection.
  # KV collections use `key` as the primary key and `value` for the payload.
  #
  #   class Session < ApplicationRecord
  #     include NodeDB::KV
  #     self.primary_key = :key
  #   end
  #
  #   Session.kv_get("sess_abc")
  #   Session.kv_set("sess_abc", "token-xyz", ttl: 3600)
  #   Session.kv_delete("sess_abc")
  module KV
    extend ActiveSupport::Concern

    class_methods do
      # NodeDB rejects qualified column refs (`"kv_sessions"."key"`), so the
      # KV helpers build raw `WHERE key = …` predicates rather than using
      # AR's hash-form `where(key: key)` which auto-qualifies.
      def kv_get(key)
        rows = connection.select_all(
          "SELECT key, value FROM #{table_name} WHERE key = #{connection.quote(key)} LIMIT 1"
        )
        rows.first&.fetch("value")
      end

      def kv_set(key, value, ttl: nil)
        if kv_exists?(key)
          connection.execute(
            "UPDATE #{table_name} SET value = #{connection.quote(value)} " \
            "WHERE key = #{connection.quote(key)}"
          )
        else
          connection.execute(
            "INSERT INTO #{table_name} (key, value) " \
            "VALUES (#{connection.quote(key)}, #{connection.quote(value)})"
          )
        end
        if ttl
          sql = NodeDB::SQL::KV.set_ttl(
            table: table_name,
            key:   connection.quote(key),
            ttl:   ttl
          )
          connection.execute(sql)
        end
        value
      end

      def kv_delete(key)
        connection.execute(
          "DELETE FROM #{table_name} WHERE key = #{connection.quote(key)}"
        )
      end

      def kv_exists?(key)
        rows = connection.select_all(
          "SELECT key FROM #{table_name} WHERE key = #{connection.quote(key)} LIMIT 1"
        )
        rows.any?
      end
    end
  end
end
