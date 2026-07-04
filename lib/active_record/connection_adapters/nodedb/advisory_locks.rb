require "securerandom"

module ActiveRecord
  module ConnectionAdapters
    module Nodedb
      # Raised by #with_advisory_lock! when the lock cannot be acquired
      # within the requested timeout.
      class FailedToAcquireLock < ActiveRecord::ActiveRecordError
        def initialize(lock_name)
          super("advisory lock '#{lock_name}' could not be acquired")
        end
      end

      # BUG-014: NodeDB has no advisory-lock primitives (upstream
      # won't-fix on the pgwire surface), so the mutex is implemented
      # application-level: a document_strict lock collection whose TEXT
      # PRIMARY KEY makes acquisition an atomic INSERT (a second insert
      # of the same key fails the PK uniqueness constraint server-side).
      #
      # Two surfaces share the machinery:
      # - AR's migrator contract (#get_advisory_lock /
      #   #release_advisory_lock) — try-lock semantics, numeric ids.
      # - A block API modeled on the with_advisory_lock gem:
      #   #with_advisory_lock / #with_advisory_lock! — guaranteed
      #   release via ensure, bounded waiting via timeout_seconds
      #   (0 = try once, nil = wait forever), thread-local reentrancy,
      #   #advisory_lock_exists? introspection, and key namespacing via
      #   the NODEDB_ADVISORY_LOCK_PREFIX env var.
      #
      # Semantics vs PostgreSQL advisory locks: NOT session-scoped — a
      # crashed holder leaves the row behind. The ensure-release of the
      # block API covers in-process failures; rows older than
      # `advisory_lock_ttl` seconds (connection config, default 3600)
      # are treated as stale and stolen on acquire.
      module AdvisoryLocks
        ADVISORY_LOCKS_COLLECTION = "ar_advisory_locks"
        ADVISORY_LOCK_TTL = 3600
        DUPLICATE_KEY_RE = /primary-key uniqueness|duplicate key/i
        LOCK_PREFIX_ENV = "NODEDB_ADVISORY_LOCK_PREFIX"

        LockResult = Struct.new(:acquired, :value) do
          alias_method :acquired?, :acquired
        end

        # ── AR migrator surface (numeric lock ids) ────────────────────
        def get_advisory_lock(lock_id)
          acquire_advisory_key(advisory_lock_key(lock_id))
        end

        def release_advisory_lock(lock_id)
          release_advisory_key(advisory_lock_key(lock_id))
        end

        # Named acquire without a block (test setup, manual coordination).
        def get_advisory_lock_named(name)
          acquire_advisory_key(advisory_lock_key(name))
        end

        # ── Block API ─────────────────────────────────────────────────
        # Returns the block's value when acquired, false otherwise
        # (use #with_advisory_lock_result when the block itself may
        # legitimately return false).
        def with_advisory_lock(name, timeout_seconds: nil, &block)
          result = with_advisory_lock_result(name, timeout_seconds: timeout_seconds, &block)
          result.acquired? ? result.value : false
        end

        # Same, but raises FailedToAcquireLock instead of returning false.
        def with_advisory_lock!(name, timeout_seconds: nil, &block)
          result = with_advisory_lock_result(name, timeout_seconds: timeout_seconds, &block)
          raise FailedToAcquireLock, name unless result.acquired?

          result.value
        end

        def with_advisory_lock_result(name, timeout_seconds: nil)
          key = advisory_lock_key(name)

          # Reentrant: same thread already inside this lock — just yield;
          # only the outermost exit releases.
          return LockResult.new(true, yield) if advisory_lock_stack.include?(key)

          deadline =
            timeout_seconds && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds

          loop do
            if acquire_advisory_key(key)
              begin
                advisory_lock_stack.push(key)
                return LockResult.new(true, yield)
              ensure
                advisory_lock_stack.pop
                release_advisory_key(key)
              end
            end

            if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              return LockResult.new(false, nil)
            end

            # Randomized backoff reduces herd contention between waiters.
            sleep(rand(0.05..0.15))
          end
        end

        def advisory_lock_exists?(name)
          !advisory_lock_row(advisory_lock_key(name)).nil?
        end

        private

        # Thread-local nesting stack of held lock keys (reentrancy).
        def advisory_lock_stack
          Thread.current[:nodedb_advisory_lock_stack] ||= []
        end

        def advisory_lock_key(name)
          "#{ENV[LOCK_PREFIX_ENV]}#{name}"
        end

        # Per-adapter-instance identity; lets release/steal distinguish
        # our lock from another process's.
        def advisory_lock_owner
          @advisory_lock_owner ||= SecureRandom.uuid
        end

        def acquire_advisory_key(key)
          ensure_advisory_lock_collection
          try_advisory_insert(key) ||
            (steal_stale_advisory_lock(key) && try_advisory_insert(key))
        end

        def release_advisory_key(key)
          row = advisory_lock_row(key)
          return false if row && row["owner"] != advisory_lock_owner

          execute(
            "DELETE FROM #{ADVISORY_LOCKS_COLLECTION} " \
            "WHERE id = #{quote(key)} AND owner = #{quote(advisory_lock_owner)}"
          )
          true
        rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
          # A dead connection can't release; the TTL steal cleans the row
          # up. Swallowing here also keeps ensure-release from masking
          # the block's real exception.
          raise unless e.message.match?(/connection|closed|refused/i)

          false
        end

        def try_advisory_insert(key)
          execute(
            "INSERT INTO #{ADVISORY_LOCKS_COLLECTION} (id, owner, acquired_at) VALUES " \
            "(#{quote(key)}, #{quote(advisory_lock_owner)}, #{quote(Time.now.to_i.to_s)})"
          )
          true
        rescue ActiveRecord::StatementInvalid => e
          raise unless e.message.match?(DUPLICATE_KEY_RE)

          false
        end

        def steal_stale_advisory_lock(key)
          row = advisory_lock_row(key)
          return false unless row

          ttl = (@config[:advisory_lock_ttl] || ADVISORY_LOCK_TTL).to_i
          return false unless Time.now.to_i - row["acquired_at"].to_i > ttl

          # Compare-and-delete on the observed owner so a fresh reacquire
          # by someone else between the read and the delete survives.
          execute(
            "DELETE FROM #{ADVISORY_LOCKS_COLLECTION} " \
            "WHERE id = #{quote(key)} AND owner = #{quote(row['owner'])}"
          )
          true
        end

        # Scan + client-side filter instead of `WHERE id = <key>`:
        # BUG-033 — a point-lookup miss poisons that key's PK-equality
        # reads for the rest of the session (INSERT/UPDATE don't
        # invalidate), and the lock flow reads exactly such a key right
        # before inserting it. The lock collection stays tiny, so the
        # scan is cheap.
        def advisory_lock_row(key)
          execute(
            "SELECT id, owner, acquired_at FROM #{ADVISORY_LOCKS_COLLECTION}"
          ).find { |row| row["id"] == key }
        end

        def ensure_advisory_lock_collection
          return if collections.include?(ADVISORY_LOCKS_COLLECTION)

          execute(
            "CREATE COLLECTION #{ADVISORY_LOCKS_COLLECTION} " \
            "(id TEXT PRIMARY KEY, owner TEXT, acquired_at TEXT) " \
            "WITH (engine='document_strict')"
          )
        rescue ActiveRecord::StatementInvalid => e
          # Another process won the create race.
          raise unless e.message.include?("already exists")
        end
      end
    end
  end
end
