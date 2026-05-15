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

    # libpq prints "could not interpret result from server: <TAG>" to fd 2
    # whenever NodeDB returns a non-standard command tag (INSERT EDGE,
    # GRAPH TRAVERSE, etc.). The query itself succeeds. Filter these specific
    # lines without dropping any real warnings.
    LIBPQ_NOISE_RE = /\Acould not interpret result from server: (INSERT EDGE|GRAPH [A-Z ]+)/

    class_methods do
      def graph_insert_edge(from:, to:, type:, properties: {})
        sql = NodeDB::SQL::Graph.insert_edge(
          in_collection:   quoted_table_name,
          from:            connection.quote(from),
          to:              connection.quote(to),
          type:            connection.quote(type),
          properties_json: connection.quote(properties.to_json)
        )
        NodeDB::Graph.silence_libpq_noise { connection.execute(sql) }
      end

      # Returns an Array of node ID strings reachable from `from` within
      # `depth` hops. NodeDB v0.2.x emits a JSON object with `nodes`/`edges`
      # keys; older versions emitted a flat array of IDs. Both are handled.
      # The starting node (`from`) is filtered out.
      def graph_traverse(from:, depth: 1, direction: :both)
        sql = NodeDB::SQL::Graph.traverse(
          from:      connection.quote(from),
          depth:     depth,
          direction: direction
        )
        raw = NodeDB::Graph.silence_libpq_noise { connection.select_all(sql) }
        payload = JSON.parse(raw.first&.fetch("result", "[]") || "[]")

        ids =
          case payload
          when Array then payload
          when Hash  then Array(payload["nodes"]).map { |n| n["id"] }.compact
          else            []
          end

        ids - [from.to_s]
      end

      def graph_algo(algo, **options)
        sql = NodeDB::SQL::Graph.algo(table: quoted_table_name, algo: algo, **options)
        NodeDB::Graph.silence_libpq_noise { connection.select_all(sql) }
      end

      def graph_delete_edge(from:, to:, type:)
        sql = NodeDB::SQL::Graph.delete_edge(
          from: connection.quote(from),
          to:   connection.quote(to),
          type: connection.quote(type)
        )
        NodeDB::Graph.silence_libpq_noise { connection.execute(sql) }
      end
    end

    # Redirect fd 2 to a pipe, run the block, then re-emit any captured
    # lines that don't match LIBPQ_NOISE_RE. Real warnings still surface.
    def self.silence_libpq_noise
      r, w = IO.pipe
      original = STDERR.dup
      STDERR.reopen(w)
      w.close
      begin
        yield
      ensure
        STDERR.reopen(original)
        original.close
        captured = r.read
        r.close
        captured.each_line do |line|
          $stderr.write(line) unless line =~ LIBPQ_NOISE_RE
        end
      end
    end
  end
end
