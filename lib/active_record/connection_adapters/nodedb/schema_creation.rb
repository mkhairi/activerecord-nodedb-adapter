module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      class SchemaCreation < PostgreSQL::SchemaCreation
        # Serialize CREATE COLLECTION DDL.
        # Delegates to NodeDB::SQL::Collection.create for the SQL string.
        def visit_create_collection(o)
          col_parts = o.columns.map { |c| accept(c) }
          NodeDB::SQL::Collection.create(o.name, engine: o.engine, columns: col_parts)
        end
      end
    end
  end
end
