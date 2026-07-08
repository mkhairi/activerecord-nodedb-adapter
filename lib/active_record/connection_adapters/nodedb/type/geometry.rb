module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      module Type
        # Cast for NodeDB GEOMETRY columns.
        #
        # Currently a thin string passthrough — we keep WKT round-tripping
        # ("POINT(lon lat)") and let the caller wrap with ST_GeomFromText
        # in INSERTs. Replace with rgeo-feature parsing once NodeDB BUG-011
        # (ST_GeomFromText not evaluated on INSERT) is resolved.
        class Geometry < ActiveModel::Type::Value
          def initialize(sql_type: nil)
            super()
          end

          def type = :geometry
          def cast(v) = v&.to_s
          def serialize(v) = cast(v)
        end
      end
    end
  end
end
