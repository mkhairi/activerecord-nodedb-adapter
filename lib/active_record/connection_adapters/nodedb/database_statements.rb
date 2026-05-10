module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      module DatabaseStatements
        # Execute a NodeDB-dialect SQL statement and return the raw result.
        # Routes through the standard ActiveRecord execute path so logging,
        # query caching, and instrumentation all work normally.
        def execute_nodedb(sql, name = nil)
          execute(sql, name)
        end
      end
    end
  end
end
