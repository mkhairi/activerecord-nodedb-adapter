require "spec_helper"

RSpec.describe ActiveRecord::ConnectionAdapters::NodedbAdapter do
  let(:conn) { ActiveRecord::Base.connection }

  it "reports correct adapter name" do
    expect(conn.adapter_name).to eq("NodeDB")
  end

  it "reports a nodedb version string", :integration do
    expect(conn.nodedb_version).to match(/\d+\.\d+/)
  end

  describe "#database_version (BUG-003 workaround)", :integration do
    it "derives the version from the server's server_version_num setting" do
      reported = conn.query_value("SELECT current_setting('server_version_num')", "SCHEMA").to_i

      if reported.positive?
        expect(conn.get_database_version).to eq(reported)
      else
        expect(conn.get_database_version)
          .to eq(described_class::FALLBACK_DATABASE_VERSION)
      end
    end

    it "returns a version high enough for AR's PostgreSQL feature guards" do
      expect(conn.database_version).to be >= 120000
    end
  end

  describe "#create_collection + #drop_collection", :integration do
    let(:name) { "test_adapter_#{SecureRandom.hex(4)}" }

    after { conn.drop_collection(name, if_exists: true) }

    it "creates and lists a schemaless collection" do
      conn.create_collection(name)
      expect(conn.collections).to include(name)
    end

    it "creates a timeseries collection" do
      conn.create_collection(name, engine: :timeseries)
      expect(conn.collections).to include(name)
    end

    it "creates a kv collection" do
      conn.create_collection(name, engine: :kv)
      expect(conn.collections).to include(name)
    end

    it "drops a collection" do
      conn.create_collection(name)
      conn.drop_collection(name)
      expect(conn.collections).not_to include(name)
    end

    it "creates a BITEMPORAL document_strict collection (NodeDB v0.3.0+)" do
      conn.create_collection(name, engine: :document_strict, bitemporal: true) do |t|
        t.text :id, primary_key: true
        t.text :title
      end

      expect(conn.collections).to include(name)
    end

    it "BITEMPORAL DDL projects user columns on plain and history reads (BUG-027 regression)" do
      conn.create_collection(name, engine: :document_strict, bitemporal: true, id: false) do |t|
        t.text :id, primary_key: true
        t.text :title
      end
      # Autocommit write — AR txn-wrapped writes are lost on bitemporal
      # collections (BUG-024).
      conn.execute("INSERT INTO #{name} (id, title) VALUES ('a', 'first')")

      plain = conn.select_all("SELECT * FROM #{name}").to_a
      expect(plain.first.keys).to contain_exactly("id", "title")

      history = conn.select_all("SELECT * FROM #{name} AS OF SYSTEM TIME NULL").to_a
      expect(history.first.keys).to include("id", "title", "_ts_system")
    end

    it "drop_collection(if_exists: true) is a no-op when collection is missing" do
      expect { conn.drop_collection("nope_#{SecureRandom.hex(4)}", if_exists: true) }
        .not_to raise_error
    end

    it "drop_collection(if_exists: true) drops an existing collection (BUG-004 fix in NodeDB v0.2.1)" do
      conn.create_collection(name)
      conn.drop_collection(name, if_exists: true)
      expect(conn.collections).not_to include(name)
    end
  end

  describe "BUG-019 pg_catalog vquery bypass", :integration do
    let(:name) { "vquery_bypass_#{SecureRandom.hex(4)}" }

    before do
      conn.create_collection(name, engine: :document_strict) do |t|
        t.text :id, primary_key: true
        t.text :title
      end
    end

    after { conn.drop_collection(name, if_exists: true) }

    it "tables returns the collection without hitting pg_class" do
      expect(conn.tables).to include(name)
    end

    it "primary_keys returns ['id'] without hitting pg_attribute joins" do
      expect(conn.primary_keys(name)).to eq(["id"])
    end

    it "indexes / foreign_keys / check_constraints return empty arrays" do
      expect(conn.indexes(name)).to eq([])
      expect(conn.foreign_keys(name)).to eq([])
      expect(conn.check_constraints(name)).to eq([])
    end

    it "load_additional_types is a no-op (vquery rejects pg_type.typelem)" do
      expect { conn.send(:load_additional_types, []) }.not_to raise_error
    end

    it "connection survives configure_connection without hitting typelem" do
      ActiveRecord::Base.connection.reconnect!
      expect(conn.execute("SHOW server_version").to_a).not_to be_empty
    end
  end

  describe "BUG-025 qualified-WHERE dequalification", :integration do
    let(:name) { "dequal_#{SecureRandom.hex(4)}" }

    before do
      conn.create_collection(name, engine: :document_strict, id: false) do |t|
        t.text :id, primary_key: true
        t.text :label
        t.integer :score
      end

      tname = name
      model = Class.new(ActiveRecord::Base) do
        self.table_name         = tname
        self.primary_key        = "id"
        self.inheritance_column = :_type_disabled
      end
      stub_const("DequalModel", model)
      DequalModel.create!(id: "r1", label: "alpha", score: 7)
      DequalModel.create!(id: "r2", label: "beta",  score: 3)
    end

    after { conn.drop_collection(name, if_exists: true) }

    it "hash-where on a non-PK column finds rows (was silently empty)" do
      expect(DequalModel.where(label: "alpha").to_a.map(&:id)).to eq(["r1"])
    end

    it "conditional count works" do
      expect(DequalModel.where(score: 7).count).to eq(1)
    end

    it "qualified Arel range predicates find rows" do
      rows = DequalModel.where(DequalModel.arel_table[:score].gteq(5)).to_a
      expect(rows.map(&:id)).to eq(["r1"])
    end

    it "grouped calculations work (max_identifier_length is not queried from the server)" do
      sums = DequalModel.group(:label).sum(:score).transform_values(&:to_f)
      expect(sums).to eq("alpha" => 7.0, "beta" => 3.0)
    end

    it "leaves JOIN statements untouched" do
      sql = %(SELECT "a"."x" FROM "a" JOIN "b" ON "a"."id" = "b"."a_id")
      expect(conn.send(:dequalify_single_table, sql)).to eq(sql)
    end

    it "leaves aliased FROM untouched" do
      sql = %(SELECT "t"."x" FROM "orders" AS "t" WHERE "t"."x" = 1)
      expect(conn.send(:dequalify_single_table, sql)).to eq(sql)
    end
  end

  describe "record.destroy under NodeDB BUG-008 (PARTIAL fix in v0.2.1)", :integration do
    let(:name) { "txn_delete_#{SecureRandom.hex(4)}" }

    before do
      conn.create_collection(name, engine: :document_strict, id: false) do |t|
        t.text :id, primary_key: true
        t.text :title
      end

      tname = name
      model = Class.new(ActiveRecord::Base) do
        self.table_name        = tname
        self.primary_key       = "id"
        self.inheritance_column = :_type_disabled
      end
      stub_const("TxnDeleteModel", model)
      TxnDeleteModel.create!(id: "row1", title: "before delete")
    end

    after { conn.drop_collection(name, if_exists: true) }

    it "exec_delete override persists destroy() despite 'NOT NULL PRIMARY KEY' triggering BUG-008" do
      TxnDeleteModel.find("row1").destroy

      expect(TxnDeleteModel.where(id: "row1").to_a).to be_empty
    end
  end
end
