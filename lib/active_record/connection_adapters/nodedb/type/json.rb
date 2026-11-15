require "json"

module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      module Type
        # Cast for NodeDB JSON / JSONB columns: stock AR Json (mutation
        # tracking, JSON-encoded writes) with two leniencies. Stored text
        # that is not valid JSON reads back as the raw String, not nil. An
        # assigned String holding JSON is parsed.
        class Json < ActiveRecord::Type::Json
          def deserialize(value)
            return value unless value.is_a?(::String)

            ::JSON.parse(value)
          rescue ::JSON::ParserError
            value
          end

          def cast(value)
            value.is_a?(::String) ? deserialize(value) : super
          end
        end
      end
    end
  end
end
