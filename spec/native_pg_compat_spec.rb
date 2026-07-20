require "spec_helper"

# Unit spec for the PG::Connection/PG::Result shim. No live NodeDB:
# a fake native connection feeds canned NodeDB::Native::Result objects.
RSpec.describe ActiveRecord::ConnectionAdapters::Nodedb::NativePGCompat do
  let(:fake_native) do
    Class.new do
      attr_reader :last_sql, :last_params

      def run(sql)
        @last_sql = sql
        NodeDB::Native::Result.new(columns: %w[a b], rows: [["1", "x"], ["2", "y"]], rows_affected: 0)
      end

      def run_params(sql, params)
        @last_sql = sql
        @last_params = params
        NodeDB::Native::Result.new(columns: ["n"], rows: [["9"]], rows_affected: 1)
      end

      def server_version = "NodeDB/0.2.1"
      def close = @closed = true
      def closed? = !!@closed
    end.new
  end

  subject(:conn) { described_class.new(fake_native) }

  describe "result surface (cast_result / add_pg_decoders contract)" do
    let(:result) { conn.async_exec("SELECT a, b FROM t") }

    it "exposes fields/values/ntuples/nfields" do
      expect(result.fields).to eq(%w[a b])
      expect(result.values).to eq([["1", "x"], ["2", "y"]])
      expect(result.ntuples).to eq(2)
      expect(result.nfields).to eq(2)
    end

    it "returns a text OID for ftype and -1 for fmod (schema drives model casting)" do
      expect(result.ftype(0)).to eq(25)
      expect(result.fmod(0)).to eq(-1)
    end

    it "supports cmd_tuples, getvalue, clear, map_types!" do
      expect(result.cmd_tuples).to eq(0)
      expect(result.getvalue(1, 0)).to eq("2")
      expect(result.map_types!(:anything)).to be(result)
      expect(result.clear).to be_nil
    end

    it "is Enumerable yielding field=>value hashes (add_pg_decoders uses row[\"oid\"])" do
      expect(result.to_a).to eq([{"a" => "1", "b" => "x"}, {"a" => "2", "b" => "y"}])
      expect(result.filter_map { |r| r["a"] }).to eq(%w[1 2])
    end
  end

  describe "raw result passthrough (post-BUG-018)" do
    it "passes a GRAPH TRAVERSE {nodes,edges} 'result' payload through untouched" do
      payload = '{"nodes":[{"id":"alice","depth":0},{"id":"bob","depth":1}],"edges":[]}'
      native = Class.new do
        define_method(:run) do |_sql|
          NodeDB::Native::Result.new(columns: ["result"], rows: [[payload]], rows_affected: 0)
        end
      end.new
      r = described_class.new(native).async_exec("GRAPH TRAVERSE FROM 'alice' DEPTH 1")

      # Must stay a single `result` cell so NodeDB::Graph#graph_traverse
      # can JSON-parse and unwrap it.
      expect(r.fields).to eq(["result"])
      expect(r.to_a).to eq([{"result" => payload}])
    end
  end

  describe "query data path" do
    it "async_exec delegates to native #run" do
      conn.async_exec("SELECT 1")
      expect(fake_native.last_sql).to eq("SELECT 1")
    end

    it "exec_params delegates to native #run_params with binds" do
      r = conn.exec_params("INSERT INTO t VALUES ($1)", ["v"])
      expect(fake_native.last_sql).to eq("INSERT INTO t VALUES ($1)")
      expect(fake_native.last_params).to eq(["v"])
      expect(r.cmd_tuples).to eq(1)
    end

    it "query delegates to native #run" do
      expect(conn.query("SELECT 1").ntuples).to eq(2)
    end
  end

  describe "transaction status tracking" do
    it "starts idle, goes intrans on BEGIN, idle on COMMIT/ROLLBACK" do
      expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
      conn.async_exec("BEGIN")
      expect(conn.transaction_status).to eq(PG::PQTRANS_INTRANS)
      conn.async_exec("COMMIT")
      expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
      conn.async_exec("BEGIN")
      conn.async_exec("ROLLBACK")
      expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
    end
  end

  describe "transaction tracking" do
    it "goes intrans on BEGIN" do
      conn.async_exec("BEGIN")
      expect(conn.transaction_status).to eq(PG::PQTRANS_INTRANS)
    end

    it "stays intrans after SAVEPOINT" do
      conn.async_exec("BEGIN")
      conn.async_exec("SAVEPOINT active_record_1")
      expect(conn.transaction_status).to eq(PG::PQTRANS_INTRANS)
    end

    it "stays intrans after ROLLBACK TO SAVEPOINT (the bug this plan fixes)" do
      conn.async_exec("BEGIN")
      conn.async_exec("ROLLBACK TO SAVEPOINT active_record_1")
      expect(conn.transaction_status).to eq(PG::PQTRANS_INTRANS)
    end

    it "stays intrans after RELEASE SAVEPOINT" do
      conn.async_exec("BEGIN")
      conn.async_exec("RELEASE SAVEPOINT active_record_1")
      expect(conn.transaction_status).to eq(PG::PQTRANS_INTRANS)
    end

    it "goes idle on COMMIT" do
      conn.async_exec("BEGIN")
      conn.async_exec("COMMIT")
      expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
    end

    it "goes idle on bare ROLLBACK" do
      conn.async_exec("BEGIN")
      conn.async_exec("ROLLBACK")
      expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
    end

    it "goes intrans on lowercase 'start transaction'" do
      conn.async_exec("start transaction")
      expect(conn.transaction_status).to eq(PG::PQTRANS_INTRANS)
    end
  end

  describe "connection lifecycle surface" do
    it "reports OK status, server_version, finished?, and closes" do
      expect(conn.status).to eq(PG::CONNECTION_OK)
      expect(conn.server_version).to eq(160_000)
      expect(conn.finished?).to be(false)
      conn.close
      expect(conn.finished?).to be(true)
    end

    it "no-ops cancel/block/socket_io/encoding/typemap setters" do
      expect { conn.cancel }.not_to raise_error
      expect { conn.block }.not_to raise_error
      expect(conn.socket_io).to be_nil
      expect { conn.set_client_encoding("UTF8") }.not_to raise_error
      expect { conn.type_map_for_queries = :x }.not_to raise_error
      expect { conn.type_map_for_results = :y }.not_to raise_error
      expect { conn.type_map_for_results.add_coder(:c) }.not_to raise_error
    end
  end

  describe "error mapping" do
    it "wraps NodeDB::QueryError as PG::Error so AR#active? can rescue it" do
      boom = Class.new do
        def run(_sql) = raise(NodeDB::QueryError, "42P01: nope")
      end.new
      expect { described_class.new(boom).async_exec("SELECT 1") }
        .to raise_error(PG::Error, /nope/)
    end
  end

  describe "#reset" do
    it "reconnects using the native connection's parameters" do
      params = {host: "localhost", port: 6433, database: "nodedb",
                username: "nodedb", password: "pw", connect_timeout: nil}
      old_native = instance_double(NodeDB::Native::Connection,
        connection_parameters: params, close: nil)
      fresh_native = instance_double(NodeDB::Native::Connection)
      allow(NodeDB::Native::Connection).to receive(:connect).with(**params).and_return(fresh_native)

      compat = described_class.new(old_native)
      expect(compat.reset).to be(compat)
      expect(NodeDB::Native::Connection).to have_received(:connect).with(**params)
    end
  end

  describe ".connect fail-closed TLS guard" do
    before do
      allow(NodeDB::Native::Connection).to receive(:connect)
    end

    it "refuses to connect when sslmode=require" do
      params = {host: "localhost", sslmode: "require"}
      expect { described_class.connect(params) }
        .to raise_error(NodeDB::ConnectionError, /does not support TLS/)
      expect(NodeDB::Native::Connection).not_to have_received(:connect)
    end

    it "refuses to connect when sslmode=verify-full" do
      params = {host: "localhost", sslmode: "verify-full"}
      expect { described_class.connect(params) }
        .to raise_error(NodeDB::ConnectionError, /does not support TLS/)
      expect(NodeDB::Native::Connection).not_to have_received(:connect)
    end

    it "refuses to connect when sslrootcert is set, even with no sslmode" do
      params = {host: "localhost", sslrootcert: "/tmp/ca.pem"}
      expect { described_class.connect(params) }
        .to raise_error(NodeDB::ConnectionError, /does not support TLS/)
      expect(NodeDB::Native::Connection).not_to have_received(:connect)
    end

    it "does not raise when sslmode=prefer" do
      fake_conn = instance_double(NodeDB::Native::Connection)
      allow(NodeDB::Native::Connection).to receive(:connect).and_return(fake_conn)
      params = {host: "localhost", sslmode: "prefer"}
      result = nil
      expect { result = described_class.connect(params) }.not_to raise_error
      expect(result).to be_a(described_class)
      expect(NodeDB::Native::Connection).to have_received(:connect)
    end

    it "does not raise when no ssl options are present" do
      fake_conn = instance_double(NodeDB::Native::Connection)
      allow(NodeDB::Native::Connection).to receive(:connect).and_return(fake_conn)
      params = {host: "localhost", port: 5433, dbname: "nodedb", user: "u", password: "p"}
      result = nil
      expect { result = described_class.connect(params) }.not_to raise_error
      expect(result).to be_a(described_class)
      expect(NodeDB::Native::Connection).to have_received(:connect)
    end
  end
end
