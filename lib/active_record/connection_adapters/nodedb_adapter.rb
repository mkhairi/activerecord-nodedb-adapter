require "active_record/connection_adapters/postgresql_adapter"
require "nodedb"
require_relative "nodedb/column"
require_relative "nodedb/database_statements"
require_relative "nodedb/schema_statements"
require_relative "nodedb/schema_creation"
require_relative "nodedb/session_settings"
require_relative "nodedb/type/vector"
require_relative "nodedb/type/geometry"
require_relative "nodedb/type/json"
require_relative "nodedb/vector"
require_relative "nodedb/graph"
require_relative "nodedb/timeseries"
require_relative "nodedb/spatial"
require_relative "nodedb/kv"
require_relative "nodedb/full_text_search"

module ActiveRecord
  module ConnectionHandling
    def nodedb_connection(config)
      conn_params = config.symbolize_keys.slice(
        :host, :port, :dbname, :user, :password, :connect_timeout,
        :keepalives, :keepalives_idle, :keepalives_interval, :keepalives_count,
        :sslmode, :sslcert, :sslkey, :sslrootcert
      )
      conn_params[:dbname] ||= conn_params.delete(:database)
      # NodeDB pgwire port default: 6432
      conn_params[:port] ||= 6432

      ConnectionAdapters::NodedbAdapter.new(
        ConnectionAdapters::NodedbAdapter.new_client(conn_params),
        logger,
        conn_params,
        config
      )
    end
  end

  module ConnectionAdapters
    class NodedbAdapter < PostgreSQLAdapter
      ADAPTER_NAME = "NodeDB"

      include Nodedb::DatabaseStatements
      include Nodedb::SchemaStatements
      include Nodedb::SessionSettings

      # NodeDB version string reported by SELECT version()
      NODEDB_VERSION_RE = /NodeDB\s+([\d.]+)/i

      def adapter_name
        ADAPTER_NAME
      end

      # Override: NodeDB uses CREATE COLLECTION, not CREATE TABLE, for
      # document/schemaless collections. Standard CREATE TABLE is still valid
      # for strict-schema tables.
      def create_table(table_name, **options, &block)
        if options[:engine]
          create_collection(table_name, engine: options[:engine], **options.except(:engine), &block)
        else
          super
        end
      end

      # NodeDB server version extracted from SELECT version().
      def nodedb_version
        @nodedb_version ||= begin
          v = query_value("SHOW server_version")
          NODEDB_VERSION_RE.match(v.to_s)&.[](1) || "unknown"
        end
      end

      # NodeDB's pgwire does not support the extended query protocol —
      # it sends DataRow without a prior RowDescription in prepared statement
      # responses. Force simple query mode so AR never calls exec_prepared.
      def prepared_statements
        false
      end

      # Override: NodeDB doesn't implement PQserverVersion() in the libpq
      # handshake, so the pg gem raises PG::ConnectionBad when asked for it.
      # Return a PostgreSQL 16.0-equivalent integer so AR's version guards pass.
      def database_version
        @database_version ||= 160000
      end

      def get_database_version
        160000
      end

      # Suppress the minimum-version check entirely.
      def check_version; end

      def supports_extensions?
        false
      end

      # NodeDB BUG-008: DELETE inside BEGIN;...COMMIT; is silently dropped on
      # commit. UPDATE/INSERT in the same transaction work fine.
      #
      # AR wraps `record.destroy` in an implicit transaction (and Rails 8 uses
      # lazy transactions, so BEGIN is materialized as part of the DELETE
      # call), meaning every destroy() silently no-ops.
      #
      # Workaround: after the AR-issued DELETE runs, if a transaction is still
      # open, commit it, re-issue the same DELETE outside any transaction
      # (which actually persists), then begin a fresh transaction so AR's
      # surrounding COMMIT closes cleanly. NodeDB tolerates the extra
      # BEGIN/COMMIT pair, and a second DELETE matching no rows is a no-op.
      #
      # Trade-off: any INSERT/UPDATE done before the DELETE in the same AR
      # transaction is committed early instead of atomically with the DELETE.
      # Acceptable for record.destroy (the only mutation in a single record's
      # destroy lifecycle is the DELETE itself).
      #
      # Remove this override once NodeDB persists DELETE inside transactions.
      def exec_delete(sql, name = nil, binds = [])
        result = super
        if transaction_open?
          raw = @raw_connection
          if raw
            raw.send(:async_exec, "COMMIT")
            raw.send(:async_exec, sql)
            raw.send(:async_exec, "BEGIN")
          end
        end
        result
      end

      # NodeDB returns standard information_schema views over pgwire;
      # fall back gracefully for schema introspection.
      def schema_creation
        Nodedb::SchemaCreation.new(self)
      end

      # Register NodeDB-specific Ruby type casters at connection bootstrap.
      # Pattern lifted from activerecord-postgis-adapter / clickhouse-activerecord:
      # extend the AR type registry so #cast / #serialize / #deserialize behave
      # for engine-specific columns (vector, geometry, json, uuid).
      #
      # NodeDB pgwire mostly returns strings; these casters convert them into
      # idiomatic Ruby on read and serialise Ruby into NodeDB literals on write.
      def initialize_type_map(m = type_map)
        super
        m.register_type "vector"   do |sql_type| Nodedb::Type::Vector.new(sql_type: sql_type) end
        m.register_type "geometry" do |sql_type| Nodedb::Type::Geometry.new(sql_type: sql_type) end
        m.register_type "json"     do            Nodedb::Type::Json.new                end
        m.register_type "jsonb"    do            Nodedb::Type::Json.new                end
      end

      # Quote NodeDB-friendly literals for engine-specific Ruby values.
      # Pattern lifted from activerecord-postgis-adapter / clickhouse-activerecord:
      # short-circuit AR's quote() for types pgwire can't auto-quote.
      #
      #   quote([0.1, 0.2, 0.3])     # => "'[0.1, 0.2, 0.3]'"   (vector literal)
      #   quote({ "k" => 1 })        # => "'{\"k\":1}'"         (JSON literal)
      def quote(value)
        case value
        when Array
          if value.all? { |v| v.is_a?(Numeric) }
            "'[" + value.map(&:to_s).join(", ") + "]'"
          else
            super
          end
        when Hash
          "'" + value.to_json.gsub("'", "''") + "'"
        else
          super
        end
      end

      private

      def column_class
        Nodedb::Column
      end

      # Use NodeDB's DESCRIBE command instead of the pg_attribute system-catalog
      # query that AR normally uses. See BUG-007.
      #
      # DESCRIBE returns: [field, type, nullable]
      # Maps to the 10-element array new_column_from_field expects:
      #   [column_name, type, default, notnull, oid, fmod, collation, comment, identity, attgenerated]
      def column_definitions(table_name)
        result = query(NodeDB::SQL::Collection.describe(table_name), "SCHEMA")
        result.reject { |row| row[0].to_s.start_with?("__") }.map do |row|
          field_name  = row[0].to_s
          nodedb_type = row[1].to_s
          nullable    = row[2].to_s == "true"
          pg_type, oid = NodeDB::TypeMap.resolve(nodedb_type)
          [field_name, pg_type, nil, !nullable, oid, -1, nil, nil, "", ""]
        end
      end

      # NodeDB has no function defaults; skip the Regexp#match? that would fail
      # if column_default is non-String.
      def has_default_function?(default_value, default)
        return false unless default.is_a?(String)
        super
      end
    end
  end
end
