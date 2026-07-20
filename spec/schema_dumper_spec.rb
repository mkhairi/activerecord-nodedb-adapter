require "spec_helper"

# The schema dumper walks SHOW COLLECTIONS, which lists tenant-homed
# collections daemon-wide — but only a session bound to that tenant can
# DESCRIBE them. The dump must skip them instead of raising (this broke
# rails db:migrate's dump step in the sample app).
#
# Fixed tenant fixture, created once and never dropped: DROP TENANT
# deadlocks once the tenant's built-in admin has inherited ownership
# (BUG-051; the old BUG-035 boot brick this comment used to cite is
# fixed upstream).
RSpec.describe "SchemaDumper vs tenant-homed collections", :integration do
  let(:conn) { ActiveRecord::Base.connection }

  before(:all) do
    # :integration skip fires per-example, after this context hook —
    # bail out ourselves so a daemon-less run (CI) doesn't error here.
    next unless NODEDB_AVAILABLE

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

  it "omits the internal ar_advisory_locks collection" do
    conn.send(:ensure_advisory_lock_collection)
    expect(conn.collections).to include("ar_advisory_locks") # precondition

    stream = StringIO.new
    conn.create_schema_dumper({}).dump(stream)

    expect(stream.string).not_to include("ar_advisory_locks")
  end

  it "emits bitemporal: true for bitemporal collections (and not for plain ones)" do
    bt = "kept_dump_bt_#{SecureRandom.hex(4)}"
    plain = "kept_dump_plain_#{SecureRandom.hex(4)}"
    conn.create_collection(bt, engine: :document_strict, bitemporal: true) do |t|
      t.text :action
    end
    conn.create_collection(plain, engine: :document_strict) do |t|
      t.text :action
    end

    stream = StringIO.new
    conn.create_schema_dumper({}).dump(stream)

    expect(stream.string).to match(/create_document_strict "#{bt}", bitemporal: true/)
    expect(stream.string).to match(/create_document_strict "#{plain}" do/)
  ensure
    conn.drop_collection(bt, if_exists: true)
    conn.drop_collection(plain, if_exists: true)
  end

  it "skips known spec-leak prefixes and honors ActiveRecord::SchemaDumper.ignore_tables" do
    leaked = "bt_spec_#{SecureRandom.hex(4)}"
    app_ignored = "myapp_tmp_#{SecureRandom.hex(4)}"
    kept = "kept_dump_#{SecureRandom.hex(4)}"
    [leaked, app_ignored, kept].each do |name|
      conn.execute("CREATE COLLECTION #{name} (id TEXT PRIMARY KEY) WITH (engine='document_strict')")
    end

    previous = ActiveRecord::SchemaDumper.ignore_tables
    ActiveRecord::SchemaDumper.ignore_tables = previous + [/\Amyapp_tmp_/]
    stream = StringIO.new
    conn.create_schema_dumper({}).dump(stream)

    expect(stream.string).not_to include(leaked)
    expect(stream.string).not_to include(app_ignored)
    expect(stream.string).to include(kept)
  ensure
    ActiveRecord::SchemaDumper.ignore_tables = previous if previous
    [leaked, app_ignored, kept].each { |name| conn.drop_collection(name, if_exists: true) }
  end

  it "keeps the explicit id PRIMARY KEY column but drops the synthetic id" do
    explicit = "kept_dump_#{SecureRandom.hex(4)}"
    synthetic = "kept_dump_#{SecureRandom.hex(4)}"
    conn.execute("CREATE COLLECTION #{explicit} (id TEXT PRIMARY KEY, name TEXT) WITH (engine='document_strict')")
    conn.execute("CREATE COLLECTION #{synthetic} (name TEXT) WITH (engine='document_strict')")

    stream = StringIO.new
    conn.create_schema_dumper({}).dump(stream)
    explicit_block = stream.string[/create_document_strict "#{explicit}".*?end/m]
    synthetic_block = stream.string[/create_document_strict "#{synthetic}".*?end/m]

    expect(explicit_block).to include(%(t.column :id, "TEXT PRIMARY KEY"))
    expect(synthetic_block).not_to include(":id")
  ensure
    conn.drop_collection(explicit, if_exists: true)
    conn.drop_collection(synthetic, if_exists: true)
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
