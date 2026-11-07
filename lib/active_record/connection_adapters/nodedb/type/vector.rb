require "json"

module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      module Type
        # Cast for NodeDB VECTOR(N) columns.
        #
        # NodeDB renders a vector three ways: `[0.1,0.2]`, `["0.1","0.2"]` and
        # `{0.1,0.2}`, depending on query shape and engine (BUG-073). We
        # accept Ruby arrays of numerics on assignment and serialise them into
        # the literal NodeDB's INSERT path expects.
        class Vector < ActiveModel::Type::Value
          attr_reader :dim

          def initialize(sql_type: nil, dim: nil)
            super()
            @dim = dim || extract_dim(sql_type)
          end

          def type = :vector
          def serializable?(value) = value.nil? || value.is_a?(Array) || value.is_a?(String)

          def cast(value)
            case value
            when nil then nil
            when Array then value.map(&:to_f)
            when String then begin
              JSON.parse(value.tr("{}", "[]")).map(&:to_f)
            rescue
              nil
            end
            end
          end

          def serialize(value)
            return nil if value.nil?
            arr = cast(value) or return nil
            "[" + arr.join(", ") + "]"
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
