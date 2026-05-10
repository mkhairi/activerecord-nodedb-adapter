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
  end
end
