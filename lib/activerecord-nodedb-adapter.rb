require "active_record"
require "activerecord_nodedb_adapter/version"

ActiveRecord::ConnectionAdapters.register(
  "nodedb",
  "ActiveRecord::ConnectionAdapters::NodedbAdapter",
  "active_record/connection_adapters/nodedb_adapter"
)

# Register the database task class so `bin/rails db:*` commands work.
# AR routes by adapter-name regex; we own the `nodedb` adapter so claim
# the `/nodedb/` pattern. The task class subclasses PostgreSQLDatabaseTasks
# and no-ops the CREATE/DROP database pieces NodeDB rejects.
ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/nodedb/database_tasks"
  ActiveRecord::Tasks::DatabaseTasks.register_task(
    /nodedb/,
    "ActiveRecord::ConnectionAdapters::Nodedb::DatabaseTasks"
  )
end
