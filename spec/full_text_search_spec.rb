require "spec_helper"

RSpec.describe NodeDB::FullTextSearch, :integration do
  let(:conn) { ActiveRecord::Base.connection }
  let(:collection_name) { "test_posts_#{SecureRandom.hex(4)}" }

  before(:each) do
    conn.create_fts(collection_name, fulltext: [:body]) do |t|
      t.column :id, "TEXT PRIMARY KEY"
      t.text :title
      t.text :body
    end

    tname = collection_name
    model_class = Class.new(ActiveRecord::Base) do
      self.table_name = tname
      self.primary_key = "id"
      include NodeDB::FullTextSearch

      fts_column :body
    end
    stub_const("TestPost", model_class)

    conn.execute(
      "INSERT INTO #{collection_name} (id, title, body) VALUES " \
      "('p1', 'A', 'neural networks and deep learning'), " \
      "('p2', 'B', 'totally unrelated gardening content')"
    )
  end

  after(:each) { conn.drop_collection(collection_name, if_exists: true) }

  it "creates the collection and fulltext index" do
    expect(conn.collections).to include(collection_name)
  end

  it "text_match filters server-side — only the matching row comes back (BUG-010 resolved upstream)" do
    hits = TestPost.fts_search("neural networks", limit: 10)
    expect(hits.map { |h| h["id"] }).to eq(["p1"])
  end

  it "returns an empty array when nothing matches" do
    expect(TestPost.fts_search("nonexistent zzzzz", limit: 10)).to eq([])
  end

  it "drop_fulltext_index is a no-op when the index is gone" do
    expect { conn.drop_fulltext_index("#{collection_name}_body_ft") }
      .not_to raise_error
    expect { conn.drop_fulltext_index("never_existed_#{SecureRandom.hex(2)}") }
      .not_to raise_error
  end
end
