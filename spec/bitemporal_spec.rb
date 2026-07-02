require "spec_helper"
require "securerandom"

RSpec.describe NodeDB::Bitemporal, :integration do
  let(:conn) { ActiveRecord::Base.connection }
  let(:name) { "bt_spec_#{SecureRandom.hex(4)}" }

  before do
    conn.create_collection(name, engine: :document_strict, bitemporal: true, id: false) do |t|
      t.text :id, primary_key: true
      t.text :status
    end

    tname = name
    model = Class.new(ActiveRecord::Base) do
      include NodeDB::Bitemporal
      self.table_name         = tname
      self.primary_key        = "id"
      self.inheritance_column = :_type_disabled
    end
    stub_const("BtOrder", model)

    BtOrder.create!(id: "o1", status: "placed")
    BtOrder.find("o1").update!(status: "shipped")
    BtOrder.create!(id: "o2", status: "placed")
  end

  after { conn.drop_collection(name, if_exists: true) }

  it "plain reads see only the current version (upstream bitemporal read fix)" do
    expect(BtOrder.find("o1").status).to eq("shipped")
    expect(BtOrder.count).to eq(2)
  end

  describe ".versions" do
    it "returns every committed version with _ts_system, oldest first" do
      rows = BtOrder.versions
      expect(rows.length).to eq(3)
      expect(rows).to all(include("_ts_system"))

      o1_statuses = rows.select { |r| r["id"] == "o1" }.map { |r| r["status"] }
      expect(o1_statuses).to eq(%w[placed shipped])
    end
  end

  describe ".history" do
    it "returns one record's version trail" do
      trail = BtOrder.history("o1")
      expect(trail.map { |r| r["status"] }).to eq(%w[placed shipped])
      expect(trail.map { |r| r["id"] }.uniq).to eq(["o1"])
    end
  end

  describe ".as_of" do
    it "returns the rows current at a past system time" do
      cutoff = BtOrder.history("o1").first["_ts_system"].to_i
      rows = BtOrder.as_of(cutoff)

      o1 = rows.find { |r| r["id"] == "o1" }
      expect(o1["status"]).to eq("placed")
    end

    it "accepts a Time and returns current rows for a future instant" do
      rows = BtOrder.as_of(Time.now + 60)
      expect(rows.map { |r| r["id"] }).to contain_exactly("o1", "o2")
      expect(rows.find { |r| r["id"] == "o1" }["status"]).to eq("shipped")
    end
  end
end
