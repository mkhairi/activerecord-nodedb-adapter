require "spec_helper"
require "socket"
require "securerandom"

# End-to-end: drive ActiveRecord over the NodeDB native binary protocol
# (transport: native) instead of pgwire, using the same document_strict
# collection pattern the pgwire specs use. Exercises connect, schema,
# model CRUD and the destroy path.
RSpec.describe "ActiveRecord over transport: native", :integration do
  def native_up?
    Socket.tcp("localhost", 6433, connect_timeout: 1) { true }
  rescue
    false
  end

  let(:conn) { ActiveRecord::Base.connection }
  let(:coll) { "nv_native_#{SecureRandom.hex(4)}" }

  before(:all) do
    skip "NodeDB native port 6433 unreachable" unless native_up?

    ActiveRecord::Base.establish_connection(
      adapter: "nodedb",
      transport: "native",
      host: "localhost",
      port: 6433,
      database: NodedbHelper::NODEDB_URL[%r{/([^/?]+)}, 1] || "nodedb_test",
      username: "nodedb",
      password: NodedbHelper::SUPERUSER_PASSWORD
    )
  end

  after(:all) do
    # Restore the shared pgwire connection for the rest of the suite.
    NodedbHelper.connect! if native_up?
  end

  before do
    conn.create_collection(coll, engine: :document_strict, id: false) do |t|
      t.text :id, primary_key: true
      t.text :name
      t.integer :score
    end
    tname = coll
    stub_const("NativeWidget", Class.new(ActiveRecord::Base) do
      self.table_name = tname
      self.primary_key = "id"
      self.inheritance_column = :_type_disabled
    end)
  end

  after {
    begin
      conn.drop_collection(coll, if_exists: true)
    rescue
      nil
    end
  }

  it "is connected through the native shim" do
    raw = conn.send(:any_raw_connection)
    expect(raw).to be_a(ActiveRecord::ConnectionAdapters::Nodedb::NativePGCompat)
    expect(conn.active?).to be(true)
  end

  it "INSERTs and SELECTs a model by primary key" do
    NativeWidget.create!(id: "a1", name: "alpha", score: 7)
    found = NativeWidget.find("a1")
    expect(found.name).to eq("alpha")
    expect(found.score).to eq(7)
  end

  it "UPDATEs a model" do
    NativeWidget.create!(id: "b1", name: "beta", score: 1)
    NativeWidget.find("b1").update!(score: 99)
    expect(NativeWidget.find("b1").score).to eq(99)
  end

  it "DESTROYs a model over the native shim" do
    NativeWidget.create!(id: "c1", name: "gamma", score: 3)
    NativeWidget.find("c1").destroy
    expect(NativeWidget.where(id: "c1").to_a).to be_empty
  end

  it "runs a raw select_all over native" do
    NativeWidget.create!(id: "d1", name: "delta", score: 5)
    rows = conn.select_all("SELECT * FROM #{coll}")
    # document_strict stores the row as a JSON `data` blob (same over pgwire).
    expect(rows.rows.join).to include("delta")
  end

  # Native SHOW routes through the DDL router, so the ops helpers
  # return real row sets, not the old `{"setting" => ""}` placeholder.
  {show_stats: %w[name value], show_metrics: %w[name value],
   show_memory: %w[engine allocated_bytes]}.each do |op, expected_keys|
    it "returns real rows for #{op} over native" do
      rows = conn.public_send(op)
      expect(rows).not_to be_empty
      expect(rows.first.keys).to include(*expected_keys)
    end
  end

  it "returns a real (possibly empty) row set for show_roles over native" do
    rows = conn.show_roles
    expect(rows).to be_an(Array)
    expect(rows.none? { |r| r.keys == ["setting"] }).to be(true)
  end
end
