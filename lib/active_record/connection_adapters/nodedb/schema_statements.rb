require "ostruct"

module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      module SchemaStatements
        # CREATE COLLECTION — NodeDB's analogue to CREATE TABLE.
        # engine: :document (default), :timeseries, :kv, :columnar, :spatial, :fts
        #
        # Example:
        #   create_collection :articles do |t|
        #     t.text :title
        #     t.vector :embedding, dim: 384
        #     t.timestamps
        #   end
        def create_collection(collection_name, engine: nil, **options, &block)
          td = create_table_definition(collection_name.to_s, **options)
          td.instance_variable_set(:@engine, engine)
          block.call(td) if block

          col_strings = td.columns.map { |c| schema_creation.accept(c) }
          sql = NodeDB::SQL::Collection.create(collection_name.to_s, engine: engine, columns: col_strings)
          execute_nodedb(sql)
        end

        # CREATE VECTOR INDEX on a collection column.
        #
        # Example:
        #   create_vector_index :idx_articles_emb, on: :articles,
        #     column: :embedding, metric: :cosine, dim: 384
        def create_vector_index(index_name, on:, column:, metric: :cosine, dim:)
          sql = "CREATE VECTOR INDEX #{index_name} " \
                "ON #{on} " \
                "METRIC #{metric.to_s.upcase} DIM #{dim.to_i}"
          execute_nodedb(sql)
        end

        # Drop a collection (NodeDB dialect).
        # NodeDB's IF EXISTS is partially broken (BUG-004): parses correctly when
        # collection is absent but treats 'IF' as a collection name when it exists.
        # Workaround: always use plain DROP COLLECTION and rescue the not-found error.
        def drop_collection(collection_name, if_exists: false)
          execute_nodedb(NodeDB::SQL::Collection.drop(collection_name.to_s))
        rescue ActiveRecord::StatementInvalid => e
          raise unless if_exists && e.message.include?("does not exist")
        end

        # List all collections in the current database.
        def collections
          execute_nodedb(NodeDB::SQL::Collection.show).map { |r| r["name"] }
        end
      end
    end
  end
end
