require "rails/generators"
require "rails/generators/active_record"

module Nodedb
  module Generators
    # rails g nodedb:vector_index articles embedding --dim=384 --metric=cosine
    #
    # Emits a create_vector_index migration named
    # idx_<collection>_<column>.
    class VectorIndexGenerator < ActiveRecord::Generators::Base
      source_root File.expand_path("templates", __dir__)

      argument :column, type: :string, banner: "column"

      class_option :dim, type: :numeric, required: true,
        desc: "Vector dimension (matches the column's VECTOR(n))"
      class_option :metric, type: :string, default: "cosine",
        desc: "Distance metric (cosine, l2, dot)"

      def create_migration_file
        migration_template "migration.rb.tt",
          "db/migrate/create_vector_index_#{collection_name}_#{column_name}.rb"
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end

      def collection_name
        name.underscore
      end

      def column_name
        column.underscore
      end

      def index_name
        "idx_#{collection_name}_#{column_name}"
      end
    end
  end
end
