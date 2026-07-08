require "active_record/schema_dumper"

module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      # Custom Rails SchemaDumper for NodeDB collections.
      #
      # The base AR SchemaDumper emits `create_table` blocks per pg_class
      # entry. NodeDB uses CREATE COLLECTION + per-engine helpers, so we
      # walk `connection.collections` and emit the engine-aware migration
      # commands the adapter ships (create_document_strict, create_timeseries,
      # create_kv, etc).
      #
      # Skips internal collections (`schema_migrations`, `ar_internal_metadata`).
      class SchemaDumper < ::ActiveRecord::SchemaDumper
        # AR makes ::SchemaDumper.new private; expose it on the subclass so
        # the adapter's `create_schema_dumper` factory can instantiate us.
        public_class_method :new

        # Engine -> migration helper name
        ENGINE_HELPER = {
          "document_strict" => "create_document_strict",
          "timeseries" => "create_timeseries",
          "kv" => "create_kv",
          "columnar" => "create_columnar",
          "spatial" => "create_spatial"
        }.freeze

        INTERNAL_TABLES = %w[schema_migrations ar_internal_metadata].freeze

        # Override Rails' `tables(stream)` step — emit our own DSL for each
        # NodeDB collection.
        def tables(stream)
          collections = @connection.collections.sort - INTERNAL_TABLES
          collections.each { |name| dump_collection(name, stream) }
        end

        private

        def dump_collection(name, stream)
          # SHOW COLLECTIONS lists tenant-homed collections daemon-wide,
          # but only a session bound to that tenant can DESCRIBE them —
          # and they don't belong in the default tenant's schema.rb.
          rows = begin
            @connection.execute("DESCRIBE #{name}").to_a
          rescue ActiveRecord::StatementInvalid
            return
          end
          engine = detect_engine(rows)
          helper = ENGINE_HELPER[engine] || "create_collection"
          user_columns = extract_user_columns(rows)

          stream.print "  #{helper} #{name.inspect}"
          stream.print ", engine: :#{engine}" if helper == "create_collection" && engine
          if user_columns.any?
            stream.puts " do |t|"
            user_columns.each do |field, type|
              stream.puts %(    t.column #{field.to_sym.inspect}, #{type.inspect})
            end
            stream.puts "  end"
          else
            stream.puts
          end
          stream.puts
        end

        def detect_engine(rows)
          storage = rows.find { |r| r["field"] == "__storage" }
          storage&.fetch("type")
        end

        def extract_user_columns(rows)
          # Drop:
          #  - the first synthetic `id TEXT (false)` row (NodeDB internal)
          #  - any `__*` markers (__storage, __collection_type, __kv_key)
          #
          # Keep the explicit `id ... PRIMARY KEY` row when present.
          seen_internal_id = false
          rows.filter_map do |row|
            field = row["field"].to_s
            next if field.start_with?("__")
            if field == "id" && !seen_internal_id && row["nullable"] == "false"
              seen_internal_id = true
              next
            end
            [field, row["type"].to_s]
          end
        end
      end
    end
  end
end
