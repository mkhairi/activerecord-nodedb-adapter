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
      def kv_get(key)
        find_by(key: key)&.value
      end

      def kv_set(key, value, ttl: nil)
        record = find_or_initialize_by(key: key)
        record.value = value
        record.save!
        if ttl
          sql = NodeDB::SQL::KV.set_ttl(
            table: quoted_table_name,
            key:   connection.quote(key),
            ttl:   ttl
          )
          connection.execute(sql)
        end
        value
      end

      def kv_delete(key)
        where(key: key).delete_all
      end

      def kv_exists?(key)
        where(key: key).exists?
      end
    end
  end
end
