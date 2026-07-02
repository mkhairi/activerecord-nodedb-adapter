module NodeDB
  # Include in a model backed by a BITEMPORAL NodeDB collection
  # (`create_collection ..., bitemporal: true`). NodeDB keeps every
  # committed version of each row; these helpers expose the system-time
  # read surface (`AS OF SYSTEM TIME <ms> | NULL`).
  #
  #   class AuditedOrder < ApplicationRecord
  #     include NodeDB::Bitemporal
  #   end
  #
  #   AuditedOrder.as_of(1.hour.ago)      # rows current at that instant
  #   AuditedOrder.versions               # full history, each row + _ts_system
  #   AuditedOrder.history(order.id)      # one record's version trail
  #
  # Rows come back as Array<Hash> (same convention as NodeDB::KV): the
  # temporal FROM-clause suffix doesn't compose with AR relations, and
  # history rows carry the extra `_ts_system` column. NodeDB does not
  # support ORDER BY / computed columns on AS OF scans yet, so history
  # ordering happens client-side on `_ts_system`.
  module Bitemporal
    extend ActiveSupport::Concern

    class_methods do
      # Rows current at the given system time. Accepts Time/DateTime or
      # a millisecond epoch Integer.
      def as_of(time)
        connection.select_all(
          "SELECT * FROM #{table_name} AS OF SYSTEM TIME #{NodeDB::Bitemporal.system_time_ms(time)}"
        ).to_a
      end

      # Every committed version of every row (audit-log semantics,
      # `AS OF SYSTEM TIME NULL`). Each row includes `_ts_system`, the
      # commit timestamp in ms. Sorted oldest-first client-side.
      def versions
        connection.select_all(
          "SELECT * FROM #{table_name} AS OF SYSTEM TIME NULL"
        ).to_a.sort_by { |row| row["_ts_system"].to_i }
      end

      # Version trail for a single record by primary key.
      def history(pk_value)
        connection.select_all(
          "SELECT * FROM #{table_name} AS OF SYSTEM TIME NULL " \
          "WHERE #{primary_key} = #{connection.quote(pk_value)}"
        ).to_a.sort_by { |row| row["_ts_system"].to_i }
      end
    end

    # Time-ish → millisecond epoch literal for AS OF SYSTEM TIME.
    def self.system_time_ms(time)
      case time
      when Integer then time
      else (time.to_time.to_f * 1000).round
      end
    end
  end
end
