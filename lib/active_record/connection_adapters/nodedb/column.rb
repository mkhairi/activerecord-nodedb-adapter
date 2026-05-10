module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      class Column < PostgreSQL::Column
        # NodeDB-specific type mapping on top of standard PostgreSQL types.
        # The pgwire layer surfaces NodeDB types using familiar PG OIDs where
        # possible; custom NodeDB types come through as unknown and are mapped
        # here by name.
        NODEDB_TYPE_MAP = {
          "vector"   => :vector,
          "geometry" => :geometry,
          "graph"    => :graph
        }.freeze

        def initialize(name, default, sql_type_metadata = nil, null = true, **kwargs)
          super
        end
      end
    end
  end
end
