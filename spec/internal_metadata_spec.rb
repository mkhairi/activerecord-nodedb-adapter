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

  # The migrator normally creates ar_internal_metadata; on a fresh
  # daemon/data directory nothing else has, so ensure it exists.
  before { meta.create_table }

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

  # Schema.define's post-load step — the stock implementation writes the
  # `key` column and crashes on our id-keyed collection.
  it "create_table_and_set_flags writes id-keyed environment + schema_sha1" do
    meta.create_table_and_set_flags("spec-env", "spec-sha1")

    expect(meta[:environment]).to eq("spec-env")
    expect(meta[:schema_sha1]).to eq("spec-sha1")
  ensure
    ActiveRecord::Base.connection.execute(
      "DELETE FROM ar_internal_metadata WHERE id IN ('environment', 'schema_sha1')"
    )
  end
end
