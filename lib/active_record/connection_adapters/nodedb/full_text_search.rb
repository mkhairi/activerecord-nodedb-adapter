module NodeDB
  # Include in a model backed by a NodeDB FTS-enabled collection.
  #
  #   class Post < ApplicationRecord
  #     include NodeDB::FullTextSearch
  #     fts_column :body, language: "english"
  #   end
  #
  #   Post.fts_search("machine learning", column: :body, limit: 20)
  #   Post.fts_search("async rust", fuzzy: true)
  module FullTextSearch
    extend ActiveSupport::Concern

    included do
      class_attribute :_fts_columns, default: {}
    end

    class_methods do
      def fts_column(name, language: "english")
        _fts_columns[name.to_sym] = { language: language }
      end

      def fts_search(query, column: _fts_columns.keys.first, limit: 20, fuzzy: false)
        sql = NodeDB::SQL::FTS.search(
          table:  quoted_table_name,
          column: connection.quote_column_name(column),
          query:  connection.quote(query),
          limit:  limit,
          fuzzy:  fuzzy
        )
        connection.select_all(sql)
      end
    end
  end
end
