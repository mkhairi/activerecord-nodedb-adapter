require "active_record"
require "activerecord_nodedb_adapter/version"

ActiveRecord::ConnectionAdapters.register(
  "nodedb",
  "ActiveRecord::ConnectionAdapters::NodedbAdapter",
  "active_record/connection_adapters/nodedb_adapter"
)
