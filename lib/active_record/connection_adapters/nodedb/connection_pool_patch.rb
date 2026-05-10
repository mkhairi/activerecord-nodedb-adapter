require "active_record/connection_adapters/abstract/connection_pool"

module ActiveRecord
  module ConnectionAdapters
    # Swap in NodeDB-aware SchemaMigration / InternalMetadata when the pool's
    # adapter is NodeDB. Other adapters keep the standard AR classes.
    class ConnectionPool
      alias_method :_orig_schema_migration,  :schema_migration
      alias_method :_orig_internal_metadata, :internal_metadata

      def schema_migration
        if nodedb_pool?
          @schema_migration ||= Nodedb::SchemaMigration.new(self)
        else
          _orig_schema_migration
        end
      end

      def internal_metadata
        if nodedb_pool?
          @internal_metadata ||= Nodedb::InternalMetadata.new(self)
        else
          _orig_internal_metadata
        end
      end

      private

      def nodedb_pool?
        db_config.adapter == "nodedb"
      end
    end
  end
end
