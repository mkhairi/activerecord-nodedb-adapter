require "json"

module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      module Type
        # Cast for NodeDB JSON / JSONB columns.
        #
        # NodeDB returns JSON columns as the raw text payload over pgwire.
        # Parse on read, encode on write so Ruby callers see Hash/Array.
        class Json < ActiveModel::Type::Value
          def type = :json

          def cast(value)
            case value
            when nil then nil
            when Hash, Array then value
            when String then begin
              JSON.parse(value)
            rescue
              value
            end
            else value
            end
          end

          def serialize(value)
            return nil if value.nil?
            value.is_a?(String) ? value : JSON.generate(value)
          end
        end
      end
    end
  end
end
