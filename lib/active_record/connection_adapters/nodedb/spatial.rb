module NodeDB
  # Include in a model backed by a NodeDB spatial collection.
  #
  #   class Location < ApplicationRecord
  #     include NodeDB::Spatial
  #   end
  #
  #   Location.within_distance(lat: 40.75, lon: -73.98, meters: 1000)
  #   Location.order_by_distance(lat: 40.75, lon: -73.98)
  module Spatial
    extend ActiveSupport::Concern

    class_methods do
      def within_distance(lat:, lon:, meters:, column: :geom)
        col = connection.quote_column_name(column)
        where(NodeDB::SQL::Spatial.within_distance(column: col, lat: lat, lon: lon, meters: meters))
      end

      def order_by_distance(lat:, lon:, column: :geom, as: :distance)
        col  = connection.quote_column_name(column)
        expr = NodeDB::SQL::Spatial.distance_expr(column: col, lat: lat, lon: lon, as: as)
        select("*, #{expr}").order(as)
      end

      def within_bbox(min_lon:, min_lat:, max_lon:, max_lat:, column: :geom)
        col = connection.quote_column_name(column)
        where(NodeDB::SQL::Spatial.bbox_filter(
          column: col, min_lon: min_lon, min_lat: min_lat,
          max_lon: max_lon, max_lat: max_lat
        ))
      end
    end
  end
end
