require "spec_helper"

RSpec.describe NodeDB::Timeseries, :integration do
  let(:conn) { ActiveRecord::Base.connection }
  let(:collection_name) { "test_metrics_#{SecureRandom.hex(4)}" }

  before(:each) do
    conn.create_collection(collection_name, engine: :timeseries)

    tname = collection_name
    model_class = Class.new(ActiveRecord::Base) do
      self.table_name = tname
      self.primary_key = nil
      include NodeDB::Timeseries
    end
    stub_const("TestMetric", model_class)

    # NodeDB timeseries: insert via the declared TIME_KEY column name (ts)
    conn.execute("INSERT INTO #{collection_name} (ts, host, cpu) VALUES ('2026-05-09 10:00:00', 'web-01', 0.45)")
    conn.execute("INSERT INTO #{collection_name} (ts, host, cpu) VALUES ('2026-05-09 10:05:00', 'web-01', 0.55)")
    conn.execute("INSERT INTO #{collection_name} (ts, host, cpu) VALUES ('2026-05-09 09:00:00', 'db-01',  0.80)")
  end

  after(:each) { conn.drop_collection(collection_name, if_exists: true) }

  it "filters with since" do
    results = TestMetric.since(Time.parse("2026-05-09 09:30:00 UTC")).to_a
    expect(results.length).to eq(2)
  end

  it "time_bucket produces valid SQL fragment" do
    bucket_expr = TestMetric.time_bucket("1 hour")
    expect(bucket_expr).to include("time_bucket('1 hour'")
    expect(bucket_expr).to include("timestamp")
  end
end
