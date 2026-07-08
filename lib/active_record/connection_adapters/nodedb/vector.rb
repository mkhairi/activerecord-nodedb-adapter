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
        _vector_columns[name.to_sym] = {dim: dim, metric: metric}
      end

      # Returns an Array of Hashes with keys "id", "surrogate", "distance".
      # NodeDB's SEARCH ... USING VECTOR() projects `id`, `_surrogate`,
      # and the computed `distance` as real result columns (identical over
      # pgwire and native). Caveat: `id` is only the document id on
      # vector-engine collections; on document collections with a vector
      # index it is a result ordinal — don't treat it as a key there.
      # Note: SEARCH parser rejects quoted identifiers — bare names required.
      def search_vector(column, embedding, limit: 10, filter: nil)
        sql = NodeDB::SQL::Vector.search(
          table: table_name,
          column: column.to_s,
          embedding: embedding,
          limit: limit,
          filter: filter
        )
        connection.select_all(sql).map do |row|
          {
            "id" => row["id"],
            "surrogate" => row["_surrogate"] && Integer(row["_surrogate"]),
            "distance" => row["distance"]&.to_f
          }
        end
      end
    end
  end
end
