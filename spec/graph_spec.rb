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

  it "reports persistent edge-store counters via #graph_stats" do
    rows = TestSocial.graph_stats

    expect(rows.length).to eq(1)
    row = rows.first
    expect(row["edge_count"].to_i).to eq(2)
    expect(row["distinct_label_count"].to_i).to eq(1)
    expect(row["labels"].to_s).to include("knows")
  end

  it "deletes an edge (IN-clause form current upstream requires)" do
    # Unique node ids: GRAPH TRAVERSE is tenant-wide (no IN clause), so
    # reused ids like alice/bob see stale edges from long-dropped
    # collections. Deletion is asserted through this collection's
    # scoped stats counter plus a traverse over ids nothing else used.
    x = "x_#{SecureRandom.hex(4)}"
    y = "y_#{SecureRandom.hex(4)}"
    conn.execute("INSERT INTO #{collection_name} (id, name) VALUES ('#{x}', 'X'), ('#{y}', 'Y')")
    TestSocial.graph_insert_edge(from: x, to: y, type: "temp")
    expect(TestSocial.graph_traverse(from: x, depth: 1)).to include(y)

    TestSocial.graph_delete_edge(from: x, to: y, type: "temp")

    expect(TestSocial.graph_stats.first["edge_count"].to_i).to eq(2)
    expect(TestSocial.graph_traverse(from: x, depth: 1)).not_to include(y)
  end

  it "exposes the per-label breakdown via #graph_stats verbose form" do
    rows = TestSocial.graph_stats(verbose: true)

    knows = rows.find { |r| r["label"].to_s == "knows" }
    expect(knows).not_to be_nil
    expect(knows["edge_count"].to_i).to eq(2)
  end
end
