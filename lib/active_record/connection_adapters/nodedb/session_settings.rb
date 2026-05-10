module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      # Block-scoped NodeDB session settings.
      #
      # Pattern lifted from clickhouse-activerecord's `with_settings` —
      # set NodeDB session variables before the block, restore on exit.
      # Useful for one-off tweaks like FTS fuzzy distance, vector probe
      # depth, or query-time memory budgets without polluting global
      # connection state.
      #
      #   conn.with_settings(fuzzy_distance: 3, vector_probes: 16) do
      #     Post.fts_search("nural networks", fuzzy: true)
      #   end
      #
      # SET <key> = <value>; … then SET <key> TO DEFAULT after.
      module SessionSettings
        def with_settings(**settings)
          return yield if settings.empty?

          previous = settings.keys.each_with_object({}) do |key, h|
            h[key] = current_setting(key)
          end

          settings.each { |k, v| set_session_setting(k, v) }
          yield
        ensure
          previous&.each { |k, v| restore_session_setting(k, v) }
        end

        private

        def current_setting(key)
          row = execute("SHOW #{key}").to_a.first rescue nil
          row&.values&.first
        end

        def set_session_setting(key, value)
          execute("SET #{key} = #{quote(value)}")
        end

        def restore_session_setting(key, prior)
          if prior.nil?
            execute("RESET #{key}")
          else
            execute("SET #{key} = #{quote(prior)}")
          end
        rescue ActiveRecord::StatementInvalid
          # NodeDB may not implement RESET / SHOW for every setting yet;
          # swallow the restore error rather than masking the block result.
        end
      end
    end
  end
end
