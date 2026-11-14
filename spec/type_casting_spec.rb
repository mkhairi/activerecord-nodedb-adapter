require "spec_helper"
require "active_record/connection_adapters/nodedb_adapter"

RSpec.describe "NodeDB type casting (no daemon)" do
  let(:conn) { ActiveRecord::Base.connection }
  let(:adapter_class) { ActiveRecord::ConnectionAdapters::NodedbAdapter }

  def reflect(rows)
    allow(conn).to receive(:query).with("DESCRIBE things", "SCHEMA").and_return(rows)
    conn.send(:reload_type_map)
    conn.columns("things").to_h { |c| [c.name, c] }
  end

  describe "attribute type registration" do
    it "registers :vector for attributes" do
      expect(ActiveRecord::Type.lookup(:vector, adapter: :nodedb))
        .to be_a(ActiveRecord::ConnectionAdapters::Nodedb::Type::Vector)
    end

    it "registers :geometry for attributes" do
      expect(ActiveRecord::Type.lookup(:geometry, adapter: :nodedb))
        .to be_a(ActiveRecord::ConnectionAdapters::Nodedb::Type::Geometry)
    end

    it "lets a model declare the README attribute" do
      expect {
        Class.new(ActiveRecord::Base) do
          def self.name = "DeclVector"
          self.table_name = "things"
          attribute :embedding, :vector
        end
      }.not_to raise_error
    end
  end

  describe "column reflection" do
    it "reflects a VECTOR column as :vector" do
      cols = reflect([["id", "TEXT PRIMARY KEY", "false"], ["emb", "VECTOR(3)", "true"], ["n", "INTEGER", "true"]])

      expect(cols["emb"].type).to eq(:vector)
      expect(cols["emb"].sql_type).to eq("VECTOR(3)")
      expect(cols["n"].type).to eq(:integer)
    end

    it "reflects a GEOMETRY column as :geometry" do
      cols = reflect([["id", "TEXT PRIMARY KEY", "false"], ["geom", "GEOMETRY", "true"]])

      expect(cols["geom"].type).to eq(:geometry)
    end

    it "casts a reflected vector from every rendering" do
      reflect([["id", "TEXT PRIMARY KEY", "false"], ["emb", "VECTOR(3)", "true"]])
      t = conn.send(:type_map).lookup(adapter_class::VECTOR_OID, -1, "VECTOR(3)")

      expect(t.dim).to eq(3)
      ["[0.5,1.5]", '["0.5","1.5"]', "{0.5,1.5}"].each do |s|
        expect(t.deserialize(s)).to eq([0.5, 1.5])
      end
    end
  end

  describe "Nodedb::Type::Json" do
    let(:json) { ActiveRecord::ConnectionAdapters::Nodedb::Type::Json.new }

    it "detects in-place edits" do
      raw = '{"a": 1}'
      v = json.deserialize(raw)
      v["b"] = 2

      expect(json.changed_in_place?(raw, v)).to be(true)
    end

    it "keeps unparseable stored text" do
      expect(json.deserialize("not json")).to eq("not json")
    end

    it "parses an assigned JSON string" do
      expect(json.cast('{"x":1}')).to eq({"x" => 1})
    end

    it "encodes a plain String on write" do
      expect(json.serialize("hello")).to eq("\"hello\"")
    end
  end
end
