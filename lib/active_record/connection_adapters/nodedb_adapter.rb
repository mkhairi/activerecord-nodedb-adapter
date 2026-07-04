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
require_relative "nodedb/advisory_locks"
require_relative "nodedb/type/vector"
require_relative "nodedb/type/geometry"
require_relative "nodedb/type/json"
require_relative "nodedb/vector"
require_relative "nodedb/graph"
require_relative "nodedb/timeseries"
require_relative "nodedb/bitemporal"
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
      include Nodedb::AdvisoryLocks

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

      # Override: NodeDB doesn't send a numeric-parseable server_version
      # ParameterStatus, so libpq's PQserverVersion() returns 0 and the pg
      # gem raises PG::ConnectionBad (BUG-003). Ask the server directly —
      # current NodeDB answers current_setting('server_version_num')
      # (e.g. 150000); fall back to a PostgreSQL 16.0-equivalent constant
      # on older builds where that setting is empty.
      FALLBACK_DATABASE_VERSION = 160000

      def database_version
        @database_version ||= get_database_version
      end

      def get_database_version
        query_value("SELECT current_setting('server_version_num')", "SCHEMA").to_i.nonzero? ||
          FALLBACK_DATABASE_VERSION
      rescue StandardError
        FALLBACK_DATABASE_VERSION
      end

      # NodeDB doesn't answer `SHOW max_identifier_length` on any
      # transport — pgwire errors with "unrecognized configuration
      # parameter", which crashes AR's grouped calculations
      # (group(:x).sum(:y) calls this to build column aliases). Use
      # PostgreSQL's default.
      def max_identifier_length
        63
      end

      # Suppress the minimum-version check entirely.
      def check_version; end

      def supports_extensions?
        false
      end

      # BUG-014 advisory locks (migrator contract + with_advisory_lock
      # block API) live in Nodedb::AdvisoryLocks.

      # NodeDB BUG-025: a WHERE predicate referencing a column with table
      # qualification ("table"."column") silently matches ZERO rows unless
      # it is a TEXT primary-key equality. ActiveRecord qualifies every
      # hash-condition it generates, so all idiomatic non-PK conditions
      # (where(name: ...), conditional count, uniqueness validation)
      # return wrong empty results without this rewrite.
      #
      # Workaround: strip the statement's own target-table qualifier from
      # single-table SELECT/UPDATE/DELETE before dispatch. Skipped for
      # JOINs and comma-FROM (where qualification is semantically load-
      # bearing); AR never emits those against NodeDB's supported surface.
      # Remove when upstream resolves qualified-ref evaluation.
      def perform_query(raw_connection, sql, binds, type_casted_binds, **kwargs)
        rewritten = dequalify_single_table(sql)
        result = super(raw_connection, rewritten, binds, type_casted_binds, **kwargs)
        realias_group_by_columns(rewritten, result)
      end

      # NodeDB BUG-030: a GROUP BY result set drops the requested alias on
      # plain-column select items (returning the base column name) and
      # reorders columns group-keys-first. Aggregate aliases survive.
      # ActiveRecord's grouped calculations (group(...).sum/count/...) read
      # each group key by its alias, so every group collapses onto a nil
      # key without this rename. Restore the aliases client-side by mapping
      # the returned base column names back to the aliases the SELECT list
      # asked for. Remove when upstream honours aliases in GROUP BY output.
      def realias_group_by_columns(sql, result)
        return result unless sql.is_a?(String) && sql.match?(GROUP_BY_SQL)

        select_list = sql[/\ASELECT\s+(.+?)\s+FROM\b/im, 1]
        return result unless select_list

        # Bare `"column" AS "alias"` items only: an aggregate's closing
        # paren sits between its quoted column and AS, so it never matches.
        remap = select_list.scan(/"([^"]+)"\s+AS\s+"([^"]+)"/).to_h
        remap.reject! { |base, aliaz| base == aliaz }
        return result if remap.empty?

        fields = result.fields
        renamed = fields.map { |f| remap[f] && !fields.include?(remap[f]) ? remap[f] : f }
        return result if renamed == fields

        RealiasedResult.new(result, renamed)
      end
      private :realias_group_by_columns

      # PG::Result's fields are immutable; expose the corrected names via a
      # thin delegator (values/ftype/fmod/... pass through untouched).
      class RealiasedResult < SimpleDelegator
        def initialize(result, fields)
          super(result)
          @fields = fields
        end

        attr_reader :fields
      end

      GROUP_BY_SQL      = /\A\s*SELECT\b.*\bGROUP\s+BY\b/im
      DEQUALIFIABLE_SQL = /\A\s*(?:SELECT|UPDATE|DELETE)\b/i
      DEQUALIFY_SKIP    = /\bJOIN\b|\bFROM\s+"[^"]+"\s*(?:,|\s+AS\b)/i

      def dequalify_single_table(sql)
        return sql unless sql.is_a?(String) && sql.match?(DEQUALIFIABLE_SQL)
        return sql if sql.match?(DEQUALIFY_SKIP)

        target = sql[/\b(?:FROM|UPDATE)\s+"([^"]+)"/i, 1]
        return sql unless target

        qualifier = "\"#{target}\"."
        return sql unless sql.include?(qualifier)

        sql.gsub(qualifier, "")
      end
      private :dequalify_single_table

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
      # libpq is happy; no stderr noise filter needed. Both transports
      # route SHOW through the DDL router upstream (BUG-022 fixed,
      # upstream), so no native fail-soft is needed.
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
      #
      # NodeDB parses the name as a bare identifier — single-quoted SQL
      # literals are not stripped and become part of the looked-up name.
      # To keep the interpolation safe, String names must match a strict
      # identifier pattern; non-matching input raises ArgumentError.
      def show_tenant(id_or_name)
        ref =
          if id_or_name.is_a?(Integer)
            id_or_name.to_s
          else
            validate_tenant_identifier!(id_or_name.to_s)
          end
        show_command("SHOW TENANT #{ref}").first
      end

      # SHOW TENANTS WITH NAME <prefix> — tenants matching a name filter.
      # NodeDB takes the filter as a bare identifier (no SQL string quoting),
      # so the filter must match a strict identifier pattern; non-matching
      # input raises ArgumentError.
      def show_tenants(name_filter)
        show_command("SHOW TENANTS WITH NAME #{validate_tenant_identifier!(name_filter.to_s)}")
      end

      # Whitelist for tenant name / filter identifiers passed to SHOW TENANT
      # and SHOW TENANTS WITH NAME. NodeDB consumes these as bare keywords,
      # so any user-supplied value is interpolated literally — restrict to
      # ASCII alnum plus `_` and `-`, leading char alnum or `_`.
      TENANT_IDENTIFIER_RE = /\A[A-Za-z0-9_][A-Za-z0-9_\-]*\z/

      def validate_tenant_identifier!(name)
        return name if TENANT_IDENTIFIER_RE.match?(name)

        raise ArgumentError,
              "tenant identifier #{name.inspect} contains characters outside " \
              "the safe set [A-Za-z0-9_-] (leading char must be alnum or _)"
      end
      private :validate_tenant_identifier!

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
