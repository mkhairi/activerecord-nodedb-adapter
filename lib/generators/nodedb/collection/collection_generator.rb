require "rails/generators"
require "rails/generators/active_record"

module Nodedb
  module Generators
    # rails g nodedb:collection articles title:text embedding:vector{384}
    #   --engine=document_strict --bitemporal
    #
    # Emits a create_collection migration. vector columns take the dim
    # from the standard attribute limit syntax (embedding:vector{384});
    # every other attribute renders as its plain t.<type> line.
    class CollectionGenerator < ActiveRecord::Generators::Base
      source_root File.expand_path("templates", __dir__)

      argument :attributes, type: :array, default: [],
        banner: "field:type field:vector{dim}"

      class_option :engine, type: :string, default: nil,
        desc: "NodeDB engine (document, document_strict, timeseries, kv, columnar, spatial)"
      class_option :bitemporal, type: :boolean, default: false,
        desc: "Add the BITEMPORAL collection modifier"

      # Rails' attribute parser only understands type{n} for built-in
      # types, so pull the dim out of field:vector{384} before NamedBase
      # parses the attributes.
      def initialize(args, *options)
        @vector_dims = {}
        args = args.map do |arg|
          if arg.is_a?(String) && (m = arg.match(/\A(\w+):vector\{(\d+)\}\z/))
            @vector_dims[m[1]] = Integer(m[2])
            "#{m[1]}:vector"
          else
            arg
          end
        end
        super
      end

      def create_migration_file
        migration_template "migration.rb.tt",
          "db/migrate/create_#{collection_name}.rb"
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end

      def collection_name
        name.underscore
      end

      def collection_options
        opts = +""
        opts << ", engine: :#{options[:engine]}" if options[:engine]
        opts << ", bitemporal: true" if options[:bitemporal]
        opts
      end

      def column_line(attribute)
        case attribute.type
        when :vector
          dim = @vector_dims[attribute.name] ||
            raise(Thor::Error, "vector column #{attribute.name} needs a dim: use #{attribute.name}:vector{384}")
          "t.vector :#{attribute.name}, dim: #{dim}"
        else
          "t.#{attribute.type} :#{attribute.name}"
        end
      end
    end
  end
end
