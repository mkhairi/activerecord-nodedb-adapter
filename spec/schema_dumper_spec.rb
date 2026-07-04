require "spec_helper"

# The schema dumper walks SHOW COLLECTIONS, which lists tenant-homed
# collections daemon-wide — but only a session bound to that tenant can
# DESCRIBE them. The dump must skip them instead of raising (this broke
# rails db:migrate's dump step in the sample app).
#
# Fixed tenant fixture, created once and never dropped: DROP USER
# leaves dangling catalog owner references that fail the daemon's boot
# integrity check (BUG-035).
RSpec.describe "SchemaDumper vs tenant-homed collections", :integration do
  let(:conn) { ActiveRecord::Base.connection }

  before(:all) do
    conn = ActiveRecord::Base.connection
    begin
      conn.show_tenant("spec_tenant")
    rescue ActiveRecord::StatementInvalid
      conn.execute("CREATE TENANT spec_tenant")
      conn.execute("CREATE USER t_spec_tenant PASSWORD 'spec-tenant-pw-1' TENANT spec_tenant")
      conn.execute("GRANT tenant_admin TO t_spec_tenant")
    end

    tenant_conn = PG.connect(host: "localhost", port: 6432, dbname: "nodedb",
                             user: "t_spec_tenant", password: "spec-tenant-pw-1")
    names = tenant_conn.exec("SHOW COLLECTIONS").to_a.map { |r| r["name"] }
    unless names.include?("spec_tenant_scratch")
      tenant_conn.exec("CREATE COLLECTION spec_tenant_scratch (id TEXT PRIMARY KEY) WITH (engine='document_strict')")
    end
    tenant_conn.close
  end

  it "dumps without raising and omits collections it cannot DESCRIBE" do
    listed = conn.execute("SHOW COLLECTIONS").to_a.map { |r| r["name"] }
    expect(listed).to include("spec_tenant_scratch") # precondition: daemon-wide listing

    stream = StringIO.new
    expect {
      conn.create_schema_dumper({}).dump(stream)
    }.not_to raise_error

    expect(stream.string).not_to include("spec_tenant_scratch")
  end
end
