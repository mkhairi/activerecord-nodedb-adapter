require "spec_helper"

RSpec.describe NodeDB::Vector, :integration do
  let(:conn) { ActiveRecord::Base.connection }
  let(:collection_name) { "test_articles_#{SecureRandom.hex(4)}" }

  before(:each) do
    conn.create_collection(collection_name)
    conn.create_vector_index(
      "idx_#{collection_name}_emb",
      on: collection_name,
      column: :embedding,
      metric: :cosine,
      dim: 3
    )

    tname = collection_name
    model_class = Class.new(ActiveRecord::Base) do
      self.table_name = tname
      include NodeDB::Vector

      vector_column :embedding, dim: 3
    end
    stub_const("TestArticle", model_class)

    conn.execute(
      "INSERT INTO #{collection_name} (id, title, embedding) VALUES " \
      "('a1', 'Intro to AI', ARRAY[0.1, 0.2, 0.3]), " \
      "('a2', 'Deep Learning', ARRAY[0.4, 0.5, 0.6])"
    )
  end

  after(:each) { conn.drop_collection(collection_name, if_exists: true) }

  it "finds nearest neighbours" do
    results = TestArticle.search_vector(:embedding, [0.1, 0.2, 0.3], limit: 1)
    expect(results.length).to eq(1)
    expect(results.first).to include("id", "surrogate", "distance")
    expect(results.first["distance"]).to be_within(0.01).of(0.0)
  end

  it "respects the limit" do
    results = TestArticle.search_vector(:embedding, [0.1, 0.2, 0.3], limit: 2)
    expect(results.length).to eq(2)
    distances = results.map { |r| r["distance"] }
    expect(distances).to eq(distances.sort)
  end
end
