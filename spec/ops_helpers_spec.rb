require "spec_helper"

# NodeDB v0.3.0 operational SHOW commands surfaced as adapter helpers.
RSpec.describe ActiveRecord::ConnectionAdapters::NodedbAdapter, :integration do
  let(:conn) { ActiveRecord::Base.connection }

  describe "#show_stats" do
    it "returns server-level counter rows with name/value columns" do
      rows = conn.show_stats

      expect(rows).not_to be_empty
      first = rows.first
      expect(first.keys).to include("name", "value")
      expect(rows.map { |r| r["name"] }).to include("version")
    end
  end

  describe "#show_metrics" do
    it "returns extended counter rows" do
      rows = conn.show_metrics

      expect(rows).not_to be_empty
      expect(rows.first.keys).to include("name", "value")
    end
  end

  describe "#show_memory" do
    it "returns per-engine memory snapshot rows" do
      rows = conn.show_memory

      expect(rows).not_to be_empty
      first = rows.first
      expect(first.keys).to include("engine", "allocated_bytes", "limit_bytes")
    end
  end

  describe "#show_roles" do
    it "returns Array<Hash> (possibly empty)" do
      expect(conn.show_roles).to be_an(Array)
    end
  end

  describe "#show_tenant" do
    it "returns the default tenant row when looked up by id 0" do
      row = conn.show_tenant(0)

      expect(row).not_to be_nil
      expect(row["tenant_id"].to_i).to eq(0)
    end
  end

  describe "#show_tenants" do
    it "returns Array<Hash> for a name filter (empty when no match)" do
      expect { conn.show_tenants("nonexistent_xyz_filter") }
        .to raise_error(ActiveRecord::StatementInvalid, /not found/)
    end
  end

  describe "#set_tenant" do
    it "accepts DEFAULT and integer id forms without raising" do
      expect { conn.set_tenant(:default) }.not_to raise_error
      expect { conn.set_tenant(0) }.not_to raise_error
    end
  end
end
