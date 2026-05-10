require "spec_helper"

RSpec.describe NodeDB::Graph, :integration do
  let(:conn) { ActiveRecord::Base.connection }
  let(:collection_name) { "test_social_#{SecureRandom.hex(4)}" }

  before(:each) do
    conn.create_collection(collection_name)

    tname = collection_name
    model_class = Class.new(ActiveRecord::Base) do
      self.table_name = tname
      include NodeDB::Graph
    end
    stub_const("TestSocial", model_class)

    conn.execute(
      "INSERT INTO #{collection_name} (id, name) VALUES ('alice', 'Alice'), ('bob', 'Bob'), ('carol', 'Carol')"
    )
    TestSocial.graph_insert_edge(from: "alice", to: "bob",   type: "knows", properties: { since: 2020 })
    TestSocial.graph_insert_edge(from: "bob",   to: "carol", type: "knows", properties: { since: 2022 })
  end

  after(:each) { conn.drop_collection(collection_name, if_exists: true) }

  it "traverses from a node at depth 1" do
    result = TestSocial.graph_traverse(from: "alice", depth: 1)
    expect(result).to include("bob")
  end

  it "traverses at depth 2" do
    result = TestSocial.graph_traverse(from: "alice", depth: 2)
    expect(result).to include("carol")
  end

  it "runs pagerank" do
    result = TestSocial.graph_algo(:pagerank, damping: 0.85, iterations: 10, tolerance: 1e-4)
    expect(result.length).to be > 0
  end
end
