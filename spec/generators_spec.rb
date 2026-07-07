require "spec_helper"
require "tmpdir"
require "fileutils"
require "rails/generators"
require "generators/nodedb/collection/collection_generator"
require "generators/nodedb/vector_index/vector_index_generator"

RSpec.describe "NodeDB generators" do
  let(:destination) { Dir.mktmpdir("nodedb_generators") }

  after { FileUtils.remove_entry(destination) }

  def generate(klass, args)
    klass.start(args, destination_root: destination)
    Dir[File.join(destination, "db/migrate/*.rb")].sole
  end

  describe Nodedb::Generators::CollectionGenerator do
    it "generates a create_collection migration with typed columns" do
      path = generate(described_class,
        ["articles", "title:text", "score:float", "embedding:vector{384}", "geom:geometry"])
      content = File.read(path)

      expect(path).to match(%r{db/migrate/\d+_create_articles\.rb$})
      expect(content).to include("class CreateArticles < ActiveRecord::Migration")
      expect(content).to include("create_collection :articles do |t|")
      expect(content).to include("t.text :title")
      expect(content).to include("t.float :score")
      expect(content).to include("t.vector :embedding, dim: 384")
      expect(content).to include("t.geometry :geom")
    end

    it "threads engine and bitemporal options" do
      content = File.read(generate(described_class,
        ["audit_logs", "actor:text", "--engine=document_strict", "--bitemporal"]))

      expect(content).to include(
        "create_collection :audit_logs, engine: :document_strict, bitemporal: true do |t|"
      )
    end
  end

  describe Nodedb::Generators::VectorIndexGenerator do
    it "generates a create_vector_index migration" do
      path = generate(described_class, ["articles", "embedding", "--dim=384"])
      content = File.read(path)

      expect(path).to match(%r{db/migrate/\d+_create_vector_index_articles_embedding\.rb$})
      expect(content).to include("create_vector_index :idx_articles_embedding,")
      expect(content).to include("on: :articles, column: :embedding, metric: :cosine, dim: 384")
    end

    it "honours a non-default metric" do
      content = File.read(generate(described_class,
        ["articles", "embedding", "--dim=128", "--metric=l2"]))

      expect(content).to include("metric: :l2, dim: 128")
    end
  end
end
