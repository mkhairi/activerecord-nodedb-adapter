require "spec_helper"

RSpec.describe ActiveRecord::ConnectionAdapters::NodedbAdapter do
  let(:conn) { ActiveRecord::Base.connection }

  it "reports correct adapter name" do
    expect(conn.adapter_name).to eq("NodeDB")
  end

  it "reports a nodedb version string", :integration do
    expect(conn.nodedb_version).to match(/\d+\.\d+/)
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
