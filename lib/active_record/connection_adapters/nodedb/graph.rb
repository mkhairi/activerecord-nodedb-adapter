module NodeDB
  # Include in an ActiveRecord model backed by a NodeDB document collection
  # that also acts as a graph (nodes + edges share the collection).
  #
  #   class SocialNode < ApplicationRecord
  #     include NodeDB::Graph
  #   end
  #
  #   SocialNode.graph_insert_edge(from: "alice", to: "bob", type: "knows", properties: { since: 2020 })
  #   SocialNode.graph_traverse(from: "alice", depth: 2)
  #   SocialNode.graph_algo(:pagerank, damping: 0.85, iterations: 20)
  module Graph
    extend ActiveSupport::Concern

    class_methods do
      def graph_insert_edge(from:, to:, type:, properties: {})
        sql = NodeDB::SQL::Graph.insert_edge(
          in_collection:   quoted_table_name,
          from:            connection.quote(from),
          to:              connection.quote(to),
          type:            connection.quote(type),
          properties_json: connection.quote(properties.to_json)
        )
        connection.execute(sql)
      end

      # Returns an Array of node ID strings.
      # NodeDB GRAPH TRAVERSE returns a single row: result = JSON array of IDs.
      def graph_traverse(from:, depth: 1, direction: :both)
        sql = NodeDB::SQL::Graph.traverse(
          from:      connection.quote(from),
          depth:     depth,
          direction: direction
        )
        raw = connection.select_all(sql)
        JSON.parse(raw.first&.fetch("result", "[]") || "[]")
      end

      def graph_algo(algo, **options)
        sql = NodeDB::SQL::Graph.algo(table: quoted_table_name, algo: algo, **options)
        connection.select_all(sql)
      end

      def graph_delete_edge(from:, to:, type:)
        sql = NodeDB::SQL::Graph.delete_edge(
          from: connection.quote(from),
          to:   connection.quote(to),
          type: connection.quote(type)
        )
        connection.execute(sql)
      end
    end
  end
end
