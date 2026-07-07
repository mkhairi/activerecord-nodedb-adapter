require "spec_helper"

RSpec.describe ActiveRecord::ConnectionAdapters::Nodedb::TableDefinition do
  let(:conn) { ActiveRecord::Base.connection }

  describe "column methods DDL" do
    def column_sql(&block)
      td = conn.send(:create_table_definition, "things")
      block.call(td)
      conn.send(:schema_creation).accept(td.columns.first)
    end

    it "emits VECTOR(dim) for t.vector" do
      expect(column_sql { |t| t.vector :embedding, dim: 384 })
        .to match(/"?embedding"?\s+VECTOR\(384\)/i)
    end

    it "requires dim: for t.vector" do
      expect { column_sql { |t| t.vector :embedding } }
        .to raise_error(ArgumentError)
    end

    it "emits GEOMETRY for t.geometry" do
      expect(column_sql { |t| t.geometry :geom })
        .to match(/"?geom"?\s+GEOMETRY/i)
    end
  end

  describe "against a live collection", :integration do
    let(:collection_name) { "test_tdef_#{SecureRandom.hex(4)}" }

    after(:each) { conn.drop_collection(collection_name, if_exists: true) }

    it "creates and round-trips vector + geometry columns" do
      conn.create_collection(collection_name, engine: :document_strict) do |t|
        t.column :id, "TEXT PRIMARY KEY"
        t.text :title
        t.vector :embedding, dim: 3
        t.geometry :geom
      end

      model = Class.new(ActiveRecord::Base) do
        def self.name = "TestTdefThing"
        include NodeDB::Vector
      end
      model.table_name = collection_name
      model.vector_column :embedding, dim: 3

      model.create!(id: "t1", title: "hello", embedding: [0.1, 0.2, 0.3])

      # DESCRIBE reports every column as text on current upstream, so prove
      # the VECTOR column exists by round-tripping a value through it.
      # Values come back as f32, so compare within tolerance.
      raw = model.find_by(title: "hello").embedding
      values = raw.is_a?(String) ? JSON.parse(raw) : raw
      expect(values.length).to eq(3)
      [0.1, 0.2, 0.3].each_with_index do |v, i|
        expect(values[i]).to be_within(0.0001).of(v)
      end
    end
  end
end
