module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      # NodeDB-typed migration column methods:
      #
      #   create_collection :articles do |t|
      #     t.text :title
      #     t.vector :embedding, dim: 384
      #     t.geometry :geom
      #   end
      #
      # Types are emitted as raw SQL strings (VECTOR(n), GEOMETRY) because
      # NodeDB's DDL surface accepts them verbatim; no native-type map entry
      # or type_to_sql plumbing is needed.
      module ColumnMethods
        def vector(name, dim:, **options)
          column(name, "VECTOR(#{Integer(dim)})", **options)
        end

        def geometry(name, **options)
          column(name, "GEOMETRY", **options)
        end
      end

      class TableDefinition < PostgreSQL::TableDefinition
        include ColumnMethods
      end
    end
  end
end
