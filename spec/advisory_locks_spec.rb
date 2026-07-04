require "spec_helper"

# BUG-014: NodeDB has no advisory-lock primitives (upstream won't-fix
# on the pgwire surface), so the adapter implements the AR migration
# mutex application-level: a document_strict lock collection whose
# TEXT PRIMARY KEY makes acquisition an atomic INSERT.
RSpec.describe "collection-based advisory locks (BUG-014)", :integration do
  let(:conn) { ActiveRecord::Base.connection }
  let(:coll) { ActiveRecord::ConnectionAdapters::NodedbAdapter::ADVISORY_LOCKS_COLLECTION }
  let(:lock_id) { rand(1_000_000..9_999_999) }

  after do
    conn.execute("DELETE FROM #{coll} WHERE id = '#{lock_id}'") rescue nil
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
