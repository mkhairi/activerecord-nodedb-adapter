require "spec_helper"
require "active_record/connection_adapters/postgresql_adapter"

RSpec.describe "Rails compatibility" do
  # NodedbAdapter#perform_query passes (raw_connection, sql, binds,
  # type_casted_binds, **kwargs) to super. If AR changes that signature,
  # every query breaks. Port the override, then move the gemspec cap.
  it "matches the perform_query signature the adapter overrides" do
    params = ActiveRecord::ConnectionAdapters::PostgreSQL::DatabaseStatements
      .instance_method(:perform_query).parameters.first(4).map(&:last)

    expect(params).to eq(%i[raw_connection sql binds type_casted_binds])
  end
end
