module NodeDB
  # Include in a model backed by a NodeDB FTS-enabled collection.
  #
  #   class Post < ApplicationRecord
  #     include NodeDB::FullTextSearch
  #     fts_column :body, language: "english"
  #   end
  #
  #   Post.fts_search("machine learning", limit: 20)
  #   Post.fts_search("nural networks", fuzzy: true)
  #
  # Returns an Array of Hashes with key "id". NodeDB's text_match()
  # predicate now filters rows server-side (BUG-010 resolved upstream),
  # so the previous bm25-score null-drop workaround is gone. Look up the
  # full record via Model.where("id = ?", id).first if you need the body.
  module FullTextSearch
    extend ActiveSupport::Concern

    included do
      class_attribute :_fts_columns, default: {}
    end

    class_methods do
      def fts_column(name, language: "english")
        _fts_columns[name.to_sym] = {language: language}
      end

      def fts_search(query, column: _fts_columns.keys.first, limit: 20, fuzzy: false)
        col = column.to_s
        quoted_q = connection.quote(query)
        fuzzy_opts = fuzzy ? ", { fuzzy: true, distance: 2 }" : ""

        # Bare identifiers — NodeDB rejects qualified column refs.
        # text_match() filters server-side (BUG-010 resolved upstream),
        # so just project the id.
        sql = "SELECT id " \
              "FROM #{table_name} " \
              "WHERE text_match(#{col}, #{quoted_q}#{fuzzy_opts}) " \
              "LIMIT #{limit.to_i}"

        connection.select_all(sql).to_a.map { |row| {"id" => row["id"]} }
      end
    end
  end
end
