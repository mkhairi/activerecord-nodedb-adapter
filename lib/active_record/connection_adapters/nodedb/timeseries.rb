module NodeDB
  # Include in a model backed by a NodeDB timeseries collection.
  #
  #   class Metric < ApplicationRecord
  #     include NodeDB::Timeseries
  #     self.primary_key = nil  # timeseries collections have no surrogate PK
  #   end
  #
  #   Metric.since(1.hour.ago).order(:ts)
  #   Metric.select(Metric.time_bucket("5 minutes")).group("bucket")
  module Timeseries
    extend ActiveSupport::Concern

    class_methods do
      def since(time)
        where(NodeDB::SQL::Timeseries.since_clause(time))
      end

      def until_time(time)
        where(NodeDB::SQL::Timeseries.until_clause(time))
      end

      def time_bucket(interval, as: :bucket)
        NodeDB::SQL::Timeseries.time_bucket(interval, as: as)
      end
    end
  end
end
