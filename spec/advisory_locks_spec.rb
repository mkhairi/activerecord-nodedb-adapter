require "spec_helper"

# NodeDB has no advisory-lock primitives (upstream won't-fix on the
# pgwire surface), so the adapter implements the AR migration
# mutex application-level: a document_strict lock collection whose
# TEXT PRIMARY KEY makes acquisition an atomic INSERT.
RSpec.describe "collection-based advisory locks", :integration do
  let(:conn) { ActiveRecord::Base.connection }
  let(:coll) { ActiveRecord::ConnectionAdapters::NodedbAdapter::ADVISORY_LOCKS_COLLECTION }
  let(:lock_id) { rand(1_000_000..9_999_999) }

  after do
    conn.execute("DELETE FROM #{coll} WHERE id = '#{lock_id}'")
  rescue
    nil
  end

  it "acquires and releases the lock" do
    expect(conn.get_advisory_lock(lock_id)).to be(true)
    row = conn.execute("SELECT id, owner FROM #{coll} WHERE id = '#{lock_id}'").first
    expect(row["id"]).to eq(lock_id.to_s)

    expect(conn.release_advisory_lock(lock_id)).to be(true)
    expect(conn.execute("SELECT id FROM #{coll} WHERE id = '#{lock_id}'").to_a).to be_empty
  end

  it "returns false when another owner holds the lock" do
    conn.get_advisory_lock(lock_id)
    conn.execute(
      "UPDATE #{coll} SET owner = 'someone-else' WHERE id = '#{lock_id}'"
    )
    expect(conn.get_advisory_lock(lock_id)).to be(false)
  end

  it "does not release a lock held by another owner" do
    conn.get_advisory_lock(lock_id)
    conn.execute("UPDATE #{coll} SET owner = 'someone-else' WHERE id = '#{lock_id}'")

    expect(conn.release_advisory_lock(lock_id)).to be(false)
    expect(conn.execute("SELECT id FROM #{coll} WHERE id = '#{lock_id}'").to_a).not_to be_empty
  end

  it "steals a stale lock older than the TTL" do
    conn.get_advisory_lock(lock_id)
    stale = (Time.now.to_i - 100_000).to_s
    conn.execute(
      "UPDATE #{coll} SET owner = 'crashed-process', acquired_at = '#{stale}' " \
      "WHERE id = '#{lock_id}'"
    )

    expect(conn.get_advisory_lock(lock_id)).to be(true)
    row = conn.execute("SELECT owner FROM #{coll} WHERE id = '#{lock_id}'").first
    expect(row["owner"]).not_to eq("crashed-process")
  end

  it "reacquires after release (full migrate/rollback cycle shape)" do
    expect(conn.get_advisory_lock(lock_id)).to be(true)
    expect(conn.release_advisory_lock(lock_id)).to be(true)
    expect(conn.get_advisory_lock(lock_id)).to be(true)
    expect(conn.release_advisory_lock(lock_id)).to be(true)
  end
end

# Block API modeled on the with_advisory_lock gem: guaranteed release,
# bounded waiting, reentrancy, introspection.
RSpec.describe "with_advisory_lock block API", :integration do
  let(:conn) { ActiveRecord::Base.connection }
  let(:coll) { ActiveRecord::ConnectionAdapters::NodedbAdapter::ADVISORY_LOCKS_COLLECTION }
  let(:name) { "spec-lock-#{SecureRandom.hex(4)}" }

  after do
    conn.execute("DELETE FROM #{coll} WHERE id = #{conn.quote(name)}")
  rescue
    nil
  end

  def lock_row
    conn.execute("SELECT owner FROM #{coll} WHERE id = #{conn.quote(name)}").first
  end

  it "yields, returns the block value, and releases afterwards" do
    result = conn.with_advisory_lock(name) do
      expect(lock_row).not_to be_nil
      :done
    end
    expect(result).to eq(:done)
    expect(lock_row).to be_nil
  end

  it "releases the lock when the block raises" do
    expect {
      conn.with_advisory_lock(name) { raise "boom" }
    }.to raise_error("boom")
    expect(lock_row).to be_nil
  end

  it "returns false without yielding when held elsewhere (timeout 0)" do
    conn.with_advisory_lock(name) do
      conn.execute("UPDATE #{coll} SET owner = 'someone-else' WHERE id = #{conn.quote(name)}")
    end
    # owner now foreign; row still present
    yielded = false
    result = conn.with_advisory_lock(name, timeout_seconds: 0) { yielded = true }
    expect(result).to be(false)
    expect(yielded).to be(false)
  end

  it "waits up to timeout_seconds before giving up" do
    conn.get_advisory_lock_named(name)
    conn.execute("UPDATE #{coll} SET owner = 'someone-else' WHERE id = #{conn.quote(name)}")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = conn.with_advisory_lock(name, timeout_seconds: 0.4) { :never }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(result).to be(false)
    expect(elapsed).to be >= 0.4
  end

  it "is reentrant within the same thread and only releases at the outermost exit" do
    conn.with_advisory_lock(name) do
      inner = conn.with_advisory_lock(name) { :inner }
      expect(inner).to eq(:inner)
      expect(lock_row).not_to be_nil # inner exit must NOT release
    end
    expect(lock_row).to be_nil
  end

  it "with_advisory_lock! raises FailedToAcquireLock when held elsewhere" do
    conn.get_advisory_lock_named(name)
    conn.execute("UPDATE #{coll} SET owner = 'someone-else' WHERE id = #{conn.quote(name)}")

    expect {
      conn.with_advisory_lock!(name, timeout_seconds: 0) { :never }
    }.to raise_error(ActiveRecord::ConnectionAdapters::Nodedb::FailedToAcquireLock, /#{name}/)
  end

  it "with_advisory_lock! returns the block value on success" do
    expect(conn.with_advisory_lock!(name) { 42 }).to eq(42)
  end

  it "advisory_lock_exists? reflects the row without acquiring" do
    expect(conn.advisory_lock_exists?(name)).to be(false)
    conn.with_advisory_lock(name) do
      expect(conn.advisory_lock_exists?(name)).to be(true)
    end
    expect(conn.advisory_lock_exists?(name)).to be(false)
  end

  it "namespaces lock keys with NODEDB_ADVISORY_LOCK_PREFIX" do
    original = ENV["NODEDB_ADVISORY_LOCK_PREFIX"]
    ENV["NODEDB_ADVISORY_LOCK_PREFIX"] = "myapp:"
    conn.with_advisory_lock(name) do
      row = conn.execute(
        "SELECT id FROM #{coll} WHERE id = #{conn.quote("myapp:#{name}")}"
      ).first
      expect(row).not_to be_nil
    end
  ensure
    ENV["NODEDB_ADVISORY_LOCK_PREFIX"] = original
    begin
      conn.execute("DELETE FROM #{coll} WHERE id = #{conn.quote("myapp:#{name}")}")
    rescue
      nil
    end
  end
end
