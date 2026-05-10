module NodeDB
  # Include in an ActiveRecord model whose collection has a vector index.
  #
  #   class Article < ApplicationRecord
  #     include NodeDB::Vector
  #     vector_column :embedding, dim: 384
  #   end
  #
  #   Article.search_vector(:embedding, my_embedding, limit: 10)
  module Vector
    extend ActiveSupport::Concern

    included do
      class_attribute :_vector_columns, default: {}
    end

    class_methods do
      def vector_column(name, dim:, metric: :cosine)
        _vector_columns[name.to_sym] = { dim: dim, metric: metric }
      end

      # Returns an Array of Hashes with keys "surrogate", "distance".
      # NodeDB's SEARCH ... USING VECTOR() returns internal surrogate IDs +
      # distances; it does not project document fields. Use surrogate IDs
      # for subsequent lookups if document content is needed.
      # Note: SEARCH parser rejects quoted identifiers — bare names required.
      def search_vector(column, embedding, limit: 10, filter: nil)
        sql = NodeDB::SQL::Vector.search(
          table:     table_name,
          column:    column.to_s,
          embedding: embedding,
          limit:     limit,
          filter:    filter
        )
        raw = connection.select_all(sql)
        raw.map do |row|
          parsed = JSON.parse(row["result"])
          { "surrogate" => parsed["_surrogate"], "distance" => parsed["distance"] }
        end
      end
    end
  end
end
