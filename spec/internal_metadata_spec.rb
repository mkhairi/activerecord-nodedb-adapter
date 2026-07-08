require "spec_helper"
require "securerandom"

# BUG-033 regression: a bare PK point-lookup miss poisons that key's
# `WHERE id =` reads for the rest of the session, and AR's migrator
# does exactly miss -> insert -> re-read on ar_internal_metadata
# ('environment'). The metadata accessors must therefore avoid bare
# PK-equality reads (scan + client filter) and upsert insert-first.
RSpec.describe "NodeDB-aware InternalMetadata (BUG-033 shapes)", :integration do
  let(:pool) { ActiveRecord::Base.connection_pool }
  let(:meta) { pool.internal_metadata }
  let(:key) { "spec_key_#{SecureRandom.hex(4)}" }

  after do
    ActiveRecord::Base.connection.execute(
    "DELETE FROM ar_internal_metadata WHERE id = '#{key}'"
  )
  rescue
    nil
  end

  it "survives the migrator's miss -> set -> read cycle on one connection" do
    # Prime the poisoned negative cache the way AR's env check does.
    expect(meta[key]).to be_nil

    meta[key] = "value-one"
    expect(meta[key]).to eq("value-one")
  end

  it "upserts without a prior existence read (no duplicate-PK crash)" do
    meta[key] = "first"
    meta[key] = "second"
    expect(meta[key]).to eq("second")
  end
end
