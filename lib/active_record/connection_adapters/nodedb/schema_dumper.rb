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
      # Skips internal collections (`schema_migrations`, `ar_internal_metadata`,
      # `ar_advisory_locks`).
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

        # ar_advisory_locks is created lazily by the migration advisory
        # lock itself, so a dumped block always collides on db:schema:load.
        INTERNAL_TABLES = %w[schema_migrations ar_internal_metadata ar_advisory_locks].freeze

        # Dev/test/spec runs share the single default nodedb database
        # (CREATE DATABASE is unusable upstream), so collections leaked by
        # an interrupted suite run would get baked into schema.rb. Ignore
        # this stack's spec/smoke prefixes by default; apps add their own
        # via ActiveRecord::SchemaDumper.ignore_tables (strings or
        # regexps, honored below like the stock dumper).
        SPEC_LEAK_PATTERNS = [
          /\Abt_spec_/, /\Adequal_/, /\Anv_native_/, /\Asmoke_/,
          /\Atest_adapter_/, /\Atest_ia_/, /\Atest_metrics_/, /\Atest_social_/
        ].freeze

        # Override Rails' `tables(stream)` step — emit our own DSL for each
        # NodeDB collection.
        def tables(stream)
          collections = @connection.collections.sort - INTERNAL_TABLES
          collections.each do |name|
            next if ignored?(name) || SPEC_LEAK_PATTERNS.any? { |p| p.match?(name) }

            dump_collection(name, stream)
          end
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
          stream.print ", bitemporal: true" if bitemporal?(name)
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

        # DESCRIBE exposes no bitemporal marker on current upstream, so
        # probe with the cheapest history read: it succeeds (0 rows) on a
        # bitemporal collection and errors "requires a bitemporal
        # collection" otherwise. Any error means "don't emit the flag".
        def bitemporal?(name)
          @connection.execute("SELECT 1 FROM #{name} FOR SYSTEM_TIME AS OF 1 LIMIT 1")
          true
        rescue ActiveRecord::StatementInvalid
          false
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
