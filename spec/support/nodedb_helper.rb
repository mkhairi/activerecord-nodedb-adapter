require "uri"
require "active_record"
require "activerecord-nodedb-adapter"

module NodedbHelper
  SUPERUSER_PASSWORD = File.read(File.expand_path("~/.local/share/nodedb/.superuser_password")).strip rescue nil
  NODEDB_URL = ENV.fetch("NODEDB_URL", "postgres://nodedb:#{SUPERUSER_PASSWORD}@localhost:6432/nodedb_test")


  def self.connect!
    uri = URI.parse(NODEDB_URL)
    ActiveRecord::Base.establish_connection(
      adapter:  "nodedb",
      host:     uri.host,
      port:     uri.port || 6432,
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
  rescue StandardError
    false
  end
end

NODEDB_AVAILABLE = NodedbHelper.connect! != false

RSpec.configure do |config|
  config.before(:each, :integration) do
    skip "NodeDB not available" unless NODEDB_AVAILABLE
  end
end
