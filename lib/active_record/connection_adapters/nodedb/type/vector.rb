require "json"

module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      module Type
        # Cast for NodeDB VECTOR(N) columns.
        #
        # NodeDB stores vectors as `[0.1, 0.2, 0.3]` (JSON-array literal). We
        # accept Ruby arrays of numerics on assignment and serialise them back
        # into the same literal NodeDB's INSERT path expects.
        class Vector < ActiveModel::Type::Value
          attr_reader :dim

          def initialize(sql_type: nil, dim: nil)
            super()
            @dim = dim || extract_dim(sql_type)
          end

          def type        = :vector
          def serializable?(value) = value.nil? || value.is_a?(Array) || value.is_a?(String)

          def cast(value)
            case value
            when nil          then nil
            when Array        then value.map(&:to_f)
            when String       then JSON.parse(value).map(&:to_f) rescue nil
            else                   nil
            end
          end

          def serialize(value)
            return nil if value.nil?
            arr = cast(value) or return nil
            "[" + arr.map(&:to_s).join(", ") + "]"
          end

          private

          def extract_dim(sql_type)
            return nil unless sql_type
            sql_type.to_s.match(/\((\d+)\)/)&.[](1)&.to_i
          end
        end
      end
    end
  end
end
