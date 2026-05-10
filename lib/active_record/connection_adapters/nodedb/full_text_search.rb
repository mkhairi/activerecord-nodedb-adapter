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
  # Returns an Array of Hashes with keys "id" and "score" (Float). Filter to
  # actual matches: NodeDB's text_match() predicate does not filter rows
  # (BUG-010 upstream — every row passes the WHERE), so we drop rows with a
  # nil/zero score client-side. Look up the full record via Model.where("id =
  # ?", id).first if you need the body.
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
        col   = column.to_s
        quoted_q = connection.quote(query)
        fuzzy_opts = fuzzy ? ", { fuzzy: true, distance: 2 }" : ""

        # Bare identifiers — NodeDB rejects qualified column refs.
        # Project id + score so we can filter false positives client-side.
        sql = "SELECT id, bm25_score(#{col}, #{quoted_q}#{fuzzy_opts}) AS bm25_score " \
              "FROM #{table_name} " \
              "WHERE text_match(#{col}, #{quoted_q}#{fuzzy_opts}) " \
              "ORDER BY bm25_score DESC " \
              "LIMIT #{limit.to_i}"

        rows = connection.select_all(sql).to_a
        rows.filter_map do |row|
          score_raw = row["bm25_score"]
          next if score_raw.nil? || score_raw.to_s.empty?
          score = score_raw.to_f
          next if score.zero?
          { "id" => row["id"], "score" => score }
        end
      end
    end
  end
end
