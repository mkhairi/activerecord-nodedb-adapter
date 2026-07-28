require "pg"

module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      # Adapts a NodeDB::Native::Connection to the slice of the
      # PG::Connection / PG::Result API that ActiveRecord 8.1's
      # PostgreSQLAdapter touches (verified against activerecord 8.1.3).
      #
      # NodeDB returns values as strings over the native protocol (same as
      # pgwire), and the NodeDB adapter already drives model attribute
      # casting from the schema (overridden #column_definitions), so the
      # result shim reports a TEXT oid for every column and lets AR's
      # existing type pipeline do the rest.
      class NativePGCompat
        # PG::Result-shaped wrapper over a NodeDB::Native::Result.
        class Result
          include Enumerable

          TEXT_OID = 25

          # Native results project the plan's declared columns the same
          # way pgwire does, so the wrapper is a straight shape adapter
          # with no blob normalisation.
          def initialize(native_result)
            @columns = native_result.fields
            @rows = native_result.values
            @cmd_tuples = native_result.cmd_tuples
          end

          def fields = @columns
          def values = @rows
          def ntuples = @rows.length
          def nfields = @columns.length
          attr_reader :cmd_tuples
          def ftype(_index) = TEXT_OID
          def fmod(_index) = -1
          def getvalue(row, col) = @rows.dig(row, col)
          def clear = nil

          # NodeDB values are already final; pg's result typemap is a no-op.
          def map_types!(_type_map) = self

          def each
            return to_enum(:each) unless block_given?

            @rows.each { |row| yield @columns.zip(row).to_h }
          end
        end

        # Stand-in for PG::TypeMapByOid (configure_connection assigns one).
        class NoopTypeMap
          def add_coder(*) = nil
          def coders = []
        end

        TXN_RE = /\A\s*(BEGIN|START\s+TRANSACTION|COMMIT|END|ROLLBACK(?!\s+TO\b))\b/i

        SSL_DEMANDING_MODES = %w[require verify-ca verify-full].freeze

        def self.connect(conn_params)
          sslmode = conn_params[:sslmode].to_s
          ssl_files = conn_params.values_at(:sslcert, :sslkey, :sslrootcert).compact
          if SSL_DEMANDING_MODES.include?(sslmode) || ssl_files.any?
            raise NodeDB::ConnectionError,
              "transport: native does not support TLS; connection refused because " \
              "sslmode=#{sslmode.empty? ? "(unset)" : sslmode} demands encryption. " \
              "Use the pgwire transport for TLS, or remove the ssl* options."
          end

          native = NodeDB::Native::Connection.connect(
            host: conn_params[:host] || "localhost",
            port: conn_params[:port] || NodeDB::Native::Connection::DEFAULT_PORT,
            database: conn_params[:dbname] || conn_params[:database],
            username: conn_params[:user] || conn_params[:username],
            password: conn_params[:password]
          )
          new(native)
        end

        def initialize(native)
          @native = native
          @txn = ::PG::PQTRANS_IDLE
          @type_map_for_results = NoopTypeMap.new
        end

        # ── Query data path (perform_query, PDS:167/169) ───────────────
        def async_exec(sql)
          track_txn(sql)
          Result.new(translate { @native.run(sql) })
        end
        alias_method :exec, :async_exec
        alias_method :query, :async_exec

        def exec_params(sql, binds)
          track_txn(sql)
          Result.new(translate { @native.run_params(sql, Array(binds)) })
        end

        # ── Transaction / connection state ─────────────────────────────
        def transaction_status = @txn
        def status = finished? ? ::PG::CONNECTION_BAD : ::PG::CONNECTION_OK
        def server_version = 160_000
        def finished? = @native.closed?

        def reset
          params = @native.respond_to?(:connection_parameters) ? @native.connection_parameters : nil
          begin
            @native.close
          rescue
            nil
          end
          raise ::PG::ConnectionBad, "native connection cannot be reset" unless params

          @native = NodeDB::Native::Connection.connect(**params)
          @txn = ::PG::PQTRANS_IDLE
          self
        end

        def close = @native.close
        def cancel = nil
        def block(_timeout = nil) = true
        def socket_io = nil

        # ── Quoting (PostgreSQL::Quoting calls these on the raw conn) ───
        # standard_conforming_strings is on, so a SQL string literal only
        # needs its single quotes doubled.
        def escape(str) = str.to_s.gsub("'", "''")
        alias_method :escape_string, :escape

        # PG#escape_identifier returns the identifier already wrapped in
        # double quotes, with embedded quotes doubled.
        def escape_identifier(str) = %("#{str.to_s.gsub('"', '""')}")

        # ── configure_connection surface (no-ops over native) ──────────
        def set_client_encoding(_enc) = nil

        def type_map_for_queries=(_map)
        end

        def type_map_for_results=(_map)
        end
        attr_reader :type_map_for_results
        def set_notice_receiver(&_blk)
        end

        private

        def track_txn(sql)
          m = TXN_RE.match(sql)
          return unless m

          @txn =
            case m[1].upcase
            when "BEGIN", "START TRANSACTION" then ::PG::PQTRANS_INTRANS
            else ::PG::PQTRANS_IDLE
            end
        end

        # AR rescues PG::Error / PG::ConnectionBad on the connection path;
        # surface native failures as those so translation works.
        def translate
          yield
        rescue NodeDB::ConnectionError => e
          raise ::PG::ConnectionBad, e.message
        rescue NodeDB::Error => e
          raise ::PG::Error, e.message
        end
      end
    end
  end
end
