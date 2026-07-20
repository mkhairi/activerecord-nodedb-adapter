require "uri"
require "active_record"
require "activerecord-nodedb-adapter"

module NodedbHelper
  SUPERUSER_PASSWORD = begin
    File.read(File.expand_path("~/.local/share/nodedb/.superuser_password")).strip
  rescue
    nil
  end
  # Default database by convention. CREATE DATABASE'd databases were
  # unusable for most of the alpha (BUG-032, since fixed upstream), and
  # every spec already isolates itself with a random-suffixed collection
  # it drops afterwards, so a dedicated test database buys nothing.
  NODEDB_URL = ENV.fetch("NODEDB_URL", "postgres://nodedb:#{SUPERUSER_PASSWORD}@localhost:6432/nodedb")

  def self.connect!
    uri = URI.parse(NODEDB_URL)
    ActiveRecord::Base.establish_connection(
      adapter: "nodedb",
      host: uri.host,
      port: uri.port || 6432,
      database: uri.path.delete_prefix("/"),
      username: uri.user,
      password: uri.password
    )
    ActiveRecord::Base.connection.verify!
  rescue ActiveRecord::ConnectionNotEstablished, StandardError => e
    warn "NodeDB not available (#{e.message}). Set NODEDB_URL or start Docker: " \
         "docker compose -f nodedb/docker-compose.yml up -d"
    false
  end

  def self.connected?
    ActiveRecord::Base.connection.active?
  rescue
    false
  end

  # Prefixes of collections specs create with random suffixes. Kept in
  # sync with SchemaDumper::SPEC_LEAK_PATTERNS (the dumper-side safety
  # net for the shared default database).
  SPEC_COLLECTION_PREFIXES = %w[
    bt_spec_ bt_dump_ cols_spec_ dequal_ kept_dump_ myapp_tmp_
    nv_native_ plain_dump_ test_adapter_ test_articles_ test_ia_
    test_metrics_ test_posts_ test_social_ test_tdef_ txn_delete_
    vquery_bypass_
  ].freeze

  # Drop collections leaked by earlier interrupted runs so they neither
  # accumulate nor collide with this run's fixtures.
  def self.sweep_leaked_collections!
    conn = ActiveRecord::Base.connection
    conn.collections.each do |name|
      next unless SPEC_COLLECTION_PREFIXES.any? { |p| name.start_with?(p) }

      begin
        conn.drop_collection(name, if_exists: true)
      rescue ActiveRecord::StatementInvalid
        nil
      end
    end
  end
end

NODEDB_AVAILABLE = NodedbHelper.connect! != false

RSpec.configure do |config|
  config.before(:each, :integration) do
    skip "NodeDB not available" unless NODEDB_AVAILABLE
  end

  # Sweep both ends: before(:suite) clears leftovers from crashed runs,
  # after(:suite) leaves the shared database clean for the next dump.
  config.before(:suite) { NodedbHelper.sweep_leaked_collections! if NODEDB_AVAILABLE }
  config.after(:suite) { NodedbHelper.sweep_leaked_collections! if NODEDB_AVAILABLE }
end
