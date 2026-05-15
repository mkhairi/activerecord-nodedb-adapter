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
        def create_collection(collection_name, engine: nil, engine_options: {}, **options, &block)
          td = create_table_definition(collection_name.to_s, **options)
          td.instance_variable_set(:@engine, engine)
          block.call(td) if block

          col_strings = td.columns.map { |c| schema_creation.accept(c) }
          sql = NodeDB::SQL::Collection.create(
            collection_name.to_s,
            engine:         engine,
            columns:        col_strings,
            engine_options: engine_options
          )
          execute_nodedb(sql)
        end

        # Engine-typed shorthands. Each builds a `WITH (engine='<engine>')`
        # collection through `create_collection` so the same block-form column
        # DSL works (`t.text :name`, etc).
        #
        # Pattern lifted from timescaledb-ruby's `create_hypertable` and
        # clickhouse-activerecord's per-engine helpers.
        def create_timeseries(name, **options, &block)
          create_collection(name, engine: :timeseries, **options, &block)
        end

        def create_kv(name, **options, &block)
          create_collection(name, engine: :kv, **options, &block)
        end

        def create_columnar(name, **options, &block)
          create_collection(name, engine: :columnar, **options, &block)
        end

        def create_spatial(name, **options, &block)
          create_collection(name, engine: :spatial, **options, &block)
        end

        def create_document_strict(name, **options, &block)
          create_collection(name, engine: :document_strict, **options, &block)
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

        # Drop a vector index. Mirror of create_vector_index.
        def drop_vector_index(index_name)
          execute_nodedb("DROP VECTOR INDEX #{index_name}")
        rescue ActiveRecord::StatementInvalid => e
          raise unless e.message.include?("does not exist")
        end

        def drop_collection(collection_name, if_exists: false)
          sql = if if_exists
                  NodeDB::SQL::Collection.drop_if_exists(collection_name.to_s)
                else
                  NodeDB::SQL::Collection.drop(collection_name.to_s)
                end
          execute_nodedb(sql)
        end

        # List all collections in the current database.
        def collections
          execute_nodedb(NodeDB::SQL::Collection.show).map { |r| r["name"] }
        end
      end
    end
  end
end
