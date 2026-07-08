require "spec_helper"

# Batch inserts ride the inherited PostgreSQL code paths: one
# multi-row VALUES statement, ON CONFLICT DO NOTHING for insert_all,
# ON CONFLICT ... DO UPDATE for upsert_all. These pin the behaviour on
# live NodeDB so an upstream regression (or an adapter override) shows
# up here instead of in an app.
RSpec.describe "insert_all / upsert_all", :integration do
  let(:conn) { ActiveRecord::Base.connection }
  let(:collection_name) { "test_ia_#{SecureRandom.hex(4)}" }
  let(:model) do
    tname = collection_name
    Class.new(ActiveRecord::Base) do
      self.table_name = tname
      def self.name = "TestInsertAll"
    end
  end

  before(:each) do
    conn.create_collection(collection_name, engine: :document_strict) do |t|
      t.column :id, "TEXT PRIMARY KEY"
      t.text :label
    end
  end

  after(:each) { conn.drop_collection(collection_name, if_exists: true) }

  it "insert_all! writes multiple rows in one statement" do
    model.insert_all!([{id: "a", label: "x"}, {id: "b", label: "y"}])
    expect(model.order(:id).pluck(:id, :label)).to eq([%w[a x], %w[b y]])
  end

  it "insert_all skips conflicting rows and keeps the rest" do
    model.insert_all!([{id: "a", label: "x"}])
    model.insert_all([{id: "a", label: "dup"}, {id: "c", label: "z"}])

    expect(model.find_by(id: "a").label).to eq("x")
    expect(model.find_by(id: "c").label).to eq("z")
  end

  it "upsert_all updates the conflicting row" do
    model.insert_all!([{id: "a", label: "x"}])
    model.upsert_all([{id: "a", label: "x2"}], unique_by: :id)

    expect(model.find_by(id: "a").label).to eq("x2")
  end

  it "returns no rows (NodeDB has no RETURNING payload)" do
    result = model.insert_all!([{id: "a", label: "x"}])
    expect(result.rows).to eq([])
  end
end
