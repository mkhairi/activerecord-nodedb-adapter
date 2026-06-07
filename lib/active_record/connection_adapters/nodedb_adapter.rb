require "active_record/connection_adapters/postgresql_adapter"
require "nodedb"
require_relative "nodedb/column"
require_relative "nodedb/database_statements"
require_relative "nodedb/schema_statements"
require_relative "nodedb/schema_creation"
require_relative "nodedb/schema_dumper"
require_relative "nodedb/schema_migration"
require_relative "nodedb/internal_metadata"
require_relative "nodedb/connection_pool_patch"
require_relative "nodedb/native_pg_compat"
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

      native = config.symbolize_keys[:transport].to_s == "native"
      # pgwire default 6432; native binary protocol default 6433.
      conn_params[:port] ||= native ? 6433 : 6432
      config = config.merge(port: conn_params[:port])

      client =
        if native
          ConnectionAdapters::Nodedb::NativePGCompat.connect(conn_params)
        else
          ConnectionAdapters::NodedbAdapter.new_client(conn_params)
        end

      ConnectionAdapters::NodedbAdapter.new(client, logger, conn_params, config)
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

      # `SHOW max_identifier_length` is not answered over the native
      # protocol; use PostgreSQL's default so identifier checks pass.
      def max_identifier_length
        return 63 if native_transport?

        super
      end

      # Suppress the minimum-version check entirely.
      def check_version; end

      def supports_extensions?
        false
      end

      # AR wraps `db:migrate` in a session-scoped advisory lock to block
      # concurrent migrations. PostgreSQL implements this via
      # `pg_try_advisory_lock(N)` / `pg_advisory_unlock(N)`; NodeDB doesn't
      # ship those functions yet, so AR raises ConcurrentMigrationError on
      # every db:migrate.
      #
      # Stub both methods to a no-op pair (always succeeds). This loses
      # cross-process migration safety — fine for single-instance alpha
      # work; will be removed when NodeDB ships advisory-lock primitives.
      def get_advisory_lock(lock_id)
        true
      end

      def release_advisory_lock(lock_id)
        true
      end

      # NodeDB BUG-008 (PARTIAL fix in v0.2.1): DELETE inside BEGIN;...COMMIT;
      # is silently dropped on commit when the target collection's primary key
      # column is declared with an explicit `NOT NULL PRIMARY KEY` clause --
      # which is exactly what ActiveRecord emits for every PK. Plain
      # `PRIMARY KEY` (implicit NOT NULL) works correctly on v0.2.1+.
      # UPDATE/INSERT in the same transaction work fine.
      #
      # AR wraps `record.destroy` in an implicit transaction (and Rails 8 uses
      # lazy transactions, so BEGIN is materialized as part of the DELETE
      # call), meaning every destroy() silently no-ops without this override.
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
      # Remove this override once NodeDB persists DELETE inside transactions
      # for collections with `NOT NULL PRIMARY KEY` columns.
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

      # Dump db/schema.rb using the NodeDB-aware dumper that emits engine
      # helpers (create_document_strict, create_timeseries, …) instead of
      # AR's standard create_table.
      def create_schema_dumper(options)
        Nodedb::SchemaDumper.new(self, options)
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

      # Shared internals: run a SHOW command and return Array<Hash>.
      # NodeDB's SHOW commands emit a standard "SELECT N" command tag so
      # libpq is happy; no stderr noise filter needed.
      def show_command(sql)
        select_all(sql).to_a
      end
      private :show_command

      # Persistent O(1) graph-stats counters (NodeDB v0.3.0+,
      # `SHOW GRAPH STATS`). When `collection` is nil, aggregates across
      # every graph collection in the tenant. Pass a pre-quoted string
      # literal as `collection` to scope to one (`connection.quote(name)`).
      def graph_stats(collection: nil, verbose: false, as_of: nil)
        sql = NodeDB::SQL::Graph.stats(collection: collection, verbose: verbose, as_of: as_of)
        rows = NodeDB::Graph.silence_libpq_noise { select_all(sql) }
        rows.to_a
      end

      # NodeDB v0.3.0 operational SHOW commands. Pass-through helpers that
      # return Array<Hash>. See the upstream docs for column semantics;
      # the adapter doesn't synthesise or rename columns.
      #
      #   SHOW ROLES   — defined roles (name, tenant_id, parent, created_at)
      #   SHOW STATS   — high-level server counters
      #   SHOW METRICS — extended counters (Prometheus-style)
      #   SHOW MEMORY  — per-engine memory budget snapshot
      def show_roles;   show_command("SHOW ROLES");   end
      def show_stats;   show_command("SHOW STATS");   end
      def show_metrics; show_command("SHOW METRICS"); end
      def show_memory;  show_command("SHOW MEMORY");  end

      # SHOW TENANT <id|name> — single tenant snapshot. Returns Hash row or nil.
      # Pass an Integer for id lookup, or a String for name lookup. NodeDB
      # v0.3.0 only resolves the default tenant via its numeric id (0); name
      # lookups for the default tenant currently return "not found".
      def show_tenant(id_or_name)
        ref =
          if id_or_name.is_a?(Integer)
            id_or_name.to_s
          else
            id_or_name.to_s
          end
        show_command("SHOW TENANT #{ref}").first
      end

      # SHOW TENANTS WITH NAME <prefix> — tenants matching a name filter.
      # NodeDB takes the filter as a bare identifier (no SQL string quoting).
      def show_tenants(name_filter)
        show_command("SHOW TENANTS WITH NAME #{name_filter}")
      end

      # SET TENANT = '<name>' | <id> | DEFAULT — superuser-only.
      # Pass nil / :default / "default" for DEFAULT, an Integer for id, or
      # any other String for name. Returns nil; raises StatementInvalid on
      # an unknown tenant or insufficient privilege.
      def set_tenant(value)
        sql =
          case value
          when nil, :default, "default" then "SET TENANT = DEFAULT"
          when Integer                  then "SET TENANT = #{value}"
          else                               "SET TENANT = #{quote(value.to_s)}"
          end
        execute(sql)
        nil
      end

      # AR's data-source existence check queries pg_class, which the
      # native protocol's SQL engine doesn't expose. Probe with NodeDB's
      # DESCRIBE instead (cheap; errors when the collection is absent).
      def data_source_exists?(name)
        return super unless native_transport?

        query(NodeDB::SQL::Collection.describe(name.to_s), "SCHEMA")
        true
      rescue ActiveRecord::StatementInvalid
        false
      end
      alias_method :table_exists?, :data_source_exists?

      # NodeDB's pg_* catalogs run through a virtual-catalog vquery
      # evaluator (upstream commit 2330063a, post-v0.2.1) that does not
      # support the expression shapes AR's schema reflection emits
      # (joins, ANY(current_schemas(false)), ::regclass casts). Native
      # protocol exposes no pg_* catalogs at all. On every transport,
      # provide NodeDB-native equivalents (DESCRIBE / SHOW COLLECTIONS)
      # or safe empties. Model attribute casting still works via the
      # overridden column_definitions; primary key comes from the column
      # list (NodeDB collections are id-keyed) or the model's explicit
      # self.primary_key.
      def tables
        collections
      end
      alias_method :data_sources, :tables

      def primary_keys(table_name)
        names = columns(table_name.to_s).map(&:name)
        names.include?("id") ? ["id"] : []
      end

      def pk_and_sequence_for(_table)
        nil # NodeDB has no sequences
      end

      def indexes(table_name)
        []
      end

      def foreign_keys(table_name)
        []
      end

      def check_constraints(table_name)
        []
      end

      # AR's stock `assume_migrated_upto_version` hardcodes
      # `INSERT INTO schema_migrations (version) …`, bypassing the
      # BUG-016 workaround that stores the version in the NodeDB-mandatory
      # `id` column. `schema_migrations` is a strict collection with only
      # an `id` field, and NodeDB enforces that strict schema on
      # `document_strict` over BOTH transports — the `version` field is
      # rejected on pgwire and native alike. (It only surfaces on the
      # `db:schema:load` / `db:prepare` path: `bin/setup` already routes
      # through `create_version`.) Always route version inserts through
      # `SchemaMigration#create_version` (which writes `id`), skipping
      # ones already recorded.
      def assume_migrated_upto_version(version)
        version = version.to_i
        sm = pool.schema_migration
        present = sm.versions.map { |v| v.to_s }
        migration_versions = pool.migration_context.migrations.map(&:version)

        wanted = migration_versions.select { |v| v < version }
        wanted << version
        wanted.uniq.each do |v|
          s = v.to_s
          next if present.include?(s) || present.include?(v.to_i.to_s)

          sm.create_version(s)
        end
      end

      # True when this connection was configured with `transport: native`
      # (NodeDB binary protocol instead of pgwire/libpq).
      def native_transport?
        @config[:transport].to_s == "native"
      end

      private

      # Reconnect must also go through the native shim, otherwise AR's
      # connect/reconnect path would PG.connect to the native port.
      def connect
        if native_transport?
          @raw_connection = Nodedb::NativePGCompat.connect(@connection_parameters)
        else
          super
        end
      rescue ConnectionNotEstablished => ex
        raise ex.set_pool(@pool)
      end

      # add_pg_decoders queries pg_type with a column set NodeDB's vquery
      # evaluator (upstream commit 2330063a, post-v0.2.1) supports, so it
      # works on pgwire — but native protocol has no pg_type catalog at all.
      # Keep the native skip; let pgwire call super.
      def add_pg_decoders
        return if native_transport?

        super
      end

      # load_additional_types references pg_type columns like `typelem` that
      # the new vquery evaluator does not expose ("eval: unknown column").
      # Skip on every transport — base types are registered by
      # initialize_type_map's static section, and model attribute casting
      # is driven by the overridden #column_definitions (DESCRIBE).
      def load_additional_types(oids = nil)
        # no-op
      end

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
