require "active_record/connection_adapters/postgresql_adapter"
require "nodedb"
require_relative "nodedb/column"
require_relative "nodedb/database_statements"
require_relative "nodedb/schema_statements"
require_relative "nodedb/schema_creation"
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

      # NodeDB returns standard information_schema views over pgwire;
      # fall back gracefully for schema introspection.
      def schema_creation
        Nodedb::SchemaCreation.new(self)
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
