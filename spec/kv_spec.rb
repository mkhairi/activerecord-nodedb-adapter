require "spec_helper"

RSpec.describe NodeDB::KV, :integration do
  let(:conn) { ActiveRecord::Base.connection }
  let(:name) { "test_kv_#{SecureRandom.hex(4)}" }
  let(:model) do
    tname = name
    Class.new(ActiveRecord::Base) do
      self.table_name = tname
      self.primary_key = :key
      include NodeDB::KV
    end
  end

  before { conn.create_collection(name, engine: :kv) }
  after { conn.drop_collection(name, if_exists: true) }

  it "kv_set overwrites an existing key" do
    model.kv_set("k1", "v1")
    model.kv_set("k1", "v2")

    expect(model.kv_get("k1")).to eq("v2")
  end

  it "kv_delete removes the key" do
    model.kv_set("k1", "v1")
    model.kv_delete("k1")

    expect(model.kv_get("k1")).to be_nil
  end
end
