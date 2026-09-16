# typed: strict
# frozen_string_literal: true

require "redis"
require "set"
require "logger"

module Minitest
  module Distributed
    module Coordinators
      # The RedisCoordinator is an implementation of the test coordinator interface
      # using a Redis stream + consumergroup for coordination.
      #
      # We assume a bunch of workers will be started at the same time. Every worker
      # will try to become the leader by trying to create the consumergroup. Only one
      # will succeed, which will then continue to populate the list of tests to run
      # to the stream.
      #
      # AFter that, all workers will start consuming from the stream. They will first
      # try to claim stale entries from other workers (determined by the `test_timeout_seconds`
      # option), and process them up to a maximum of `max_attempts` attempts. Then,
      # they will consume tests from the stream, run them, and ack them. This is done
      # in batches to reduce load on Redis.
      #
      # Retrying failed tests (up to `max_attempts` times) uses the same mechanism.
      # When a test fails, and we haven't exhausted the maximum number of attempts, we
      # do not ACK the result with Redis. The means that another worker will eventually
      # claim the test, and run it again. However, in this case we don't want to slow
      # things down unnecessarily. When a test fails and we want to retry it, we add the
      # test to the `retry_set` in Redis. When other worker sees that a test is in this
      # set, it can immediately claim the test, rather than waiting for the timeout.
      #
      # Finally, when we have acked the same number of tests as we populated into the
      # queue, the run is considered finished. The first worker to detect this will
      # remove the consumergroup and the associated stream from Redis.
      #
      # If a worker starts for the same run_id while it is already considered completed,
      # it will start a "retry run". It will find all the tests that failed/errored on
      # the previous attempt, and schedule only those tests to be run, rather than the
      # full test suite returned by the test selector. This can be useful to retry flaky
      # tests. Subsequent workers coming online will join this worker to form a consumer
      # group exactly as described above.
      class RedisCoordinator
        extend T::Sig
        include CoordinatorInterface

        class StallProbe < T::Struct
          const :acks, T.nilable(Integer)
          const :size, T.nilable(Integer)
          const :pending_count, Integer
          const :lag, T.nilable(Integer)
          const :production_complete, T::Boolean
          const :production_heartbeat, T.nilable(Integer)
        end
        private_constant :StallProbe

        sig { returns(Configuration) }
        attr_reader :configuration

        sig { returns(String) }
        attr_reader :stream_key

        sig { returns(String) }
        attr_reader :group_name

        sig { override.returns(ResultAggregate) }
        attr_reader :local_results

        sig { returns(T::Set[EnqueuedRunnable]) }
        attr_reader :reclaimed_timeout_tests

        sig { returns(T::Set[EnqueuedRunnable]) }
        attr_reader :reclaimed_failed_tests

        sig { returns(T.nilable(String)) }
        attr_reader :stall_diagnostic

        sig { params(configuration: Configuration).void }
        def initialize(configuration:)
          @configuration = configuration

          @redis = T.let(nil, T.nilable(Redis))
          @register_consumergroup_script = T.let(nil, T.nilable(String))
          @commit_results_script = T.let(nil, T.nilable(String))
          @cleanup_script = T.let(nil, T.nilable(String))
          @abort_script = T.let(nil, T.nilable(String))
          @adjust_results_script = T.let(nil, T.nilable(String))
          @publish_tests_script = T.let(nil, T.nilable(String))
          @heartbeat_script = T.let(nil, T.nilable(String))
          @mark_attempt_state_script = T.let(nil, T.nilable(String))
          @stream_key = T.let(key("queue"), String)
          @group_name = T.let(BASE_GROUP_NAME, String)
          @attempt_generation = T.let(nil, T.nilable(String))
          @production_complete = T.let(false, T::Boolean)
          @local_results = T.let(ResultAggregate.new, ResultAggregate)
          @combined_results = T.let(nil, T.nilable(ResultAggregate))
          @reclaimed_timeout_tests = T.let(Set.new, T::Set[EnqueuedRunnable])
          @reclaimed_failed_tests = T.let(Set.new, T::Set[EnqueuedRunnable])
          @aborted = T.let(false, T::Boolean)
          @stall_diagnostic = T.let(nil, T.nilable(String))
          @output = T.let(nil, T.untyped)
        end

        sig { override.params(reporter: Minitest::CompositeReporter, options: T::Hash[Symbol, T.untyped]).void }
        def register_reporters(reporter:, options:)
          @output = options[:io]
          reporter << Reporters::RedisCoordinatorWarningsReporter.new(options[:io], options)
        end

        sig { override.returns(ResultAggregate) }
        def combined_results
          @combined_results ||= begin
            stats_as_string = redis.mget(
              key("runs"),
              key("assertions"),
              key("passes"),
              key("failures"),
              key("errors"),
              key("skips"),
              key("requeues"),
              key("discards"),
              key("acks"),
              key("size"),
            )

            ResultAggregate.new(
              max_failures: configuration.max_failures,

              runs: Integer(stats_as_string.fetch(0) || 0),
              assertions: Integer(stats_as_string.fetch(1) || 0),
              passes: Integer(stats_as_string.fetch(2) || 0),
              failures: Integer(stats_as_string.fetch(3) || 0),
              errors: Integer(stats_as_string.fetch(4) || 0),
              skips: Integer(stats_as_string.fetch(5) || 0),
              requeues: Integer(stats_as_string.fetch(6) || 0),
              discards: Integer(stats_as_string.fetch(7) || 0),
              acks: Integer(stats_as_string.fetch(8) || 0),

              # In the case where we have no build size number published yet, we initialize
              # thesize of the test suite to be arbitrarity large, to make sure it is
              # higher than the number of acks, so the run is not consider completed yet.
              size: Integer(stats_as_string.fetch(9) || 2_147_483_647),
            )
          end
        end

        sig { override.returns(T::Boolean) }
        def aborted?
          @aborted
        end

        sig { returns(T::Boolean) }
        def stalled?
          !stall_diagnostic.nil?
        end

        sig { override.params(test_selector: TestSelector).void }
        def produce(test_selector:)
          production_heartbeat_thread = T.let(nil, T.nilable(Thread))

          registration_keys = [
            stream_key,
            key("attempt_generation"),
            key("stalled"),
            key("production_complete"),
            key("production_heartbeat"),
            key("retry_set"),
          ]
          registration_keys.concat(STATS_KEY_NAMES.map { |name| key(name) })
          registration_keys.concat(LIST_KEY_RESULT_TYPES.map { |result_type| list_key(result_type.serialize) })
          registration_keys.push(key("truncated"), key("completed_at"))
          registration = T.unsafe(execute_script(
            script_name: :register_consumergroup,
            keys: registration_keys,
            argv: [
              BASE_GROUP_NAME,
              configuration.key_ttl_seconds,
              configuration.max_failures || "",
              SecureRandom.uuid,
              COMPLETED_ATTEMPT_GRACE_SECONDS,
            ],
          ))

          leader = registration.fetch(0) == 1
          @attempt_generation = String(registration.fetch(1))
          @group_name = "#{BASE_GROUP_NAME}-#{@attempt_generation}"
          return unless leader

          registration_mode = Integer(registration.fetch(2))
          previous_failures = T.cast(registration.fetch(3), T::Array[String])
          previous_errors = T.cast(registration.fetch(4), T::Array[String])
          production_heartbeat_thread = start_production_heartbeat

          tests = T.let(
            case registration_mode
            when 0 # First attempt for a new run ID.
              tests_from_selector = test_selector.tests
              adjust_combined_results(
                ResultAggregate.new(size: tests_from_selector.size),
                allow_missing_stats: true,
              )
              tests_from_selector
            when 1 # Valid completed attempt; use selective retry behavior.
              if configuration.retry_failures
                total_failures = previous_failures.length + previous_errors.length
                adjust_combined_results(
                  ResultAggregate.new(
                    size: total_failures,
                    failures: -previous_failures.length,
                    errors: -previous_errors.length,
                    requeues: total_failures,
                  ),
                  clear_retry_lists: true,
                )

                test_identifiers_to_retry = T.let(previous_failures + previous_errors, T::Array[String])
                test_identifiers_to_retry.map { |identifier| DefinedRunnable.from_identifier(identifier) }
              else
                adjust_combined_results(ResultAggregate.new(size: 0))
                []
              end
            when 2 # Inconsistent or explicitly stalled state; rerun everything.
              emit_message(<<~WARNING)
                WARNING: The previous attempt lost Redis coordinator state.
                Running the full test suite instead of a selective retry.
              WARNING
              tests_from_selector = test_selector.tests
              adjust_combined_results(
                ResultAggregate.new(size: tests_from_selector.size),
                allow_missing_stats: true,
              )
              tests_from_selector
            when 3 # The previous attempt intentionally stopped at max_failures.
              @aborted = true
              adjust_combined_results(ResultAggregate.new(size: 0))
              []
            else
              raise "Unknown Redis registration mode: #{registration_mode}"
            end,
            T::Array[Minitest::Runnable],
          )

          publish_tests(tests)
        ensure
          stop_production_heartbeat(production_heartbeat_thread) if production_heartbeat_thread
        end

        # The loop intentionally keeps the stale/fresh claim and diagnostic state
        # transitions together so each iteration observes one coherent snapshot.
        # rubocop:disable Metrics/BlockNesting, Lint/RedundantCopDisableDirective
        sig { override.params(reporter: AbstractReporter).void }
        def consume(reporter:)
          exponential_backoff = INITIAL_BACKOFF
          last_progress_at = monotonic_time
          initial_results = combined_results
          observed_acks = T.let(initial_results.acks, T.nilable(Integer))
          observed_size = T.let(initial_results.size, T.nilable(Integer))
          observed_production_heartbeat = current_production_heartbeat
          pending_stall_warning_emitted = T.let(false, T::Boolean)
          drained_mismatch_detected_at = T.let(nil, T.nilable(Float))
          incomplete_production_detected_at = T.let(nil, T.nilable(Float))

          loop do
            # First, see if there are any pending tests from other workers to claim.
            stale_runnables = claim_stale_runnables
            process_batch(stale_runnables, reporter)

            # Then, try to process a regular batch of messages
            fresh_runnables = claim_fresh_runnables(block: exponential_backoff)
            process_batch(fresh_runnables, reporter)

            run_results = combined_results

            # If we have acked the same amount of tests as we were supposed to, the run
            # is complete and we can exit our loop. Generally, only one worker will detect
            # this condition. The other workers will quit their consumer loop because the
            # consumer group will be deleted by the first worker, and their Redis commands
            # will start to fail - see the rescue block below. Counters can be 0/0 before
            # an empty run finishes publishing, so production completion is also required.
            break if run_complete?(run_results)

            # We also abort a run if we reach the maximum number of failures.
            if run_results.abort?
              mark_run_truncated
              break
            end

            processed_batch = stale_runnables.any? || fresh_runnables.any?
            if processed_batch
              last_progress_at = monotonic_time
              observed_acks = run_results.acks
              observed_size = run_results.size
              drained_mismatch_detected_at = nil
              incomplete_production_detected_at = nil
            else
              now = monotonic_time
              confirmation_interval = [configuration.stall_timeout_seconds, STALL_CONFIRMATION_SECONDS].min
              confirmation_due = if drained_mismatch_detected_at
                now - drained_mismatch_detected_at >= confirmation_interval
              elsif incomplete_production_detected_at
                now - incomplete_production_detected_at >= configuration.stall_timeout_seconds
              else
                true
              end

              if now - last_progress_at >= configuration.stall_timeout_seconds && confirmation_due
                probe = probe_stall
                @combined_results = nil

                # Another worker may have completed the run while our memoized aggregate
                # was stale. Treat the fresh counters as authoritative.
                if probe.production_complete && !probe.acks.nil? && probe.acks == probe.size
                  break
                end

                counters_changed = probe.acks != observed_acks || probe.size != observed_size
                heartbeat_changed = probe.production_heartbeat != observed_production_heartbeat
                if counters_changed
                  observed_acks = probe.acks
                  observed_size = probe.size
                end
                observed_production_heartbeat = probe.production_heartbeat

                stream_empty = probe.pending_count.zero? && probe.lag == 0
                if probe.production_complete && stream_empty
                  incomplete_production_detected_at = nil
                  if drained_mismatch_detected_at && !counters_changed
                    abort_stalled_run(probe)
                    break
                  else
                    # The probe is pipelined rather than transactional. Confirm an
                    # unchanged mismatch so a final atomic commit interleaved with the
                    # probe cannot cause a false abort.
                    drained_mismatch_detected_at = now
                  end
                elsif !probe.production_complete && stream_empty
                  drained_mismatch_detected_at = nil
                  production_progressed = counters_changed || heartbeat_changed
                  if incomplete_production_detected_at && !production_progressed
                    abort_stalled_run(probe)
                    break
                  elsif production_progressed
                    # A live leader refreshes this heartbeat while it selects and
                    # publishes tests, so arbitrarily slow discovery is not mistaken
                    # for a dead producer.
                    incomplete_production_detected_at = nil
                    last_progress_at = now
                  else
                    # No producer heartbeat was observed. Confirm once more after a
                    # full stall interval before declaring the leader dead.
                    incomplete_production_detected_at = now
                  end
                else
                  drained_mismatch_detected_at = nil
                  incomplete_production_detected_at = nil

                  if probe.pending_count > 0 && !pending_stall_warning_emitted
                    emit_message(format_pending_stall_warning(probe))
                    pending_stall_warning_emitted = true
                  end

                  # A non-empty PEL may be waiting for the legitimate
                  # test_timeout_seconds * test_batch_size reclaim path. Undelivered
                  # entries can likewise be claimed by another worker. Wait another
                  # full interval before probing again.
                  last_progress_at = now
                end
              end
            end

            # To make sure we don't end up in a busy loop overwhelming Redis with commands
            # when there is no work to do, we increase the blocking time exponentially,
            # and reset it to the initial value if we processed any tests.
            #
            # The backoff is capped at MAX_BACKOFF to bound how long a worker can sit
            # inside a single XREADGROUP BLOCK call. Without a cap, after ~15 empty
            # iterations the worker is blocked in Redis for 5+ minutes and cannot
            # re-check `complete?` / `abort?` until the BLOCK returns, which manifests
            # as a long post-100% teardown hang when pipelined XACKs race the progress
            # reporter.
            exponential_backoff = if processed_batch
              INITIAL_BACKOFF
            else
              next_backoff(exponential_backoff)
            end
          end

          cleanup
        rescue Redis::CommandError => ce
          coordinator_state_error = ce.message.start_with?(
            "NOGROUP",
            "COORDINATORSTATE",
            "COORDINATORSTREAM",
            "STALEATTEMPT",
          ) || ce.message.include?("no such key")
          if coordinator_state_error
            # A normal cleanup and missing/evicted state can produce similar Redis
            # errors. Fresh counters distinguish a terminal run from data loss.
            handle_coordinator_state_error(ce)
            cleanup if stalled?
          else
            raise
          end
        ensure
          # Another worker may commit the final batch and clean up while this
          # worker is unwinding from NOGROUP. Report and validate against one
          # last fresh aggregate rather than a pre-cleanup local cache.
          @combined_results = nil
        end
        # rubocop:enable Metrics/BlockNesting, Lint/RedundantCopDisableDirective

        private

        sig { returns(Redis) }
        def redis
          @redis ||= Redis.new(
            url: configuration.coordinator_uri.to_s,
            middlewares: custom_middlewares,
            custom: custom_config,
            timeout: 2,
          )
        end

        sig { returns(T.nilable(T::Array[T.untyped])) }
        def custom_middlewares
          return unless ENV.key?("MINITEST_DISTRIBUTED_REDIS_LOG")

          require_relative "redis_instrumentation_middleware"
          [RedisInstrumentationMiddleware]
        end

        sig { returns(T.nilable(T::Hash[Symbol, File])) }
        def custom_config
          { log_file: logger }.compact
        end

        sig { returns(String) }
        def register_consumergroup_script
          @register_consumergroup_script ||= redis.script(:load, <<~LUA)
            -- KEYS: stream, generation token, stalled, production_complete,
            -- production_heartbeat, retry_set, ten statistics, the
            -- skipped/failed/error lists, truncated, then completed_at.
            local stream_exists = redis.call('EXISTS', KEYS[1]) == 1
            local current_generation = redis.call('GET', KEYS[2])
            local stalled = redis.call('EXISTS', KEYS[3]) == 1
            local truncated = redis.call('EXISTS', KEYS[20]) == 1
            local invalid_active_state = false

            local required_stats = {}
            for key_index = 7, 16 do
              required_stats[#required_stats + 1] = KEYS[key_index]
            end
            local existing_stat_count = redis.call('EXISTS', unpack(required_stats))

            -- An active attempt has both a stream and a generation token. A
            -- production-complete 0/0 or fully-acked stream is terminal even if
            -- its last worker died before cleanup; let the normal retry snapshot
            -- path take ownership instead of joining it as an empty follower.
            if stream_exists and current_generation and not stalled and not truncated then
              local completed = false
              local invalid_terminal_counters = false
              if existing_stat_count == 10 and redis.call('EXISTS', KEYS[4]) == 1 then
                local acks_type = redis.call('TYPE', KEYS[15]).ok
                local size_type = redis.call('TYPE', KEYS[16]).ok
                local acks = nil
                local size = nil
                if acks_type == 'string' then
                  acks = tonumber(redis.call('GET', KEYS[15]))
                end
                if size_type == 'string' then
                  size = tonumber(redis.call('GET', KEYS[16]))
                end
                invalid_terminal_counters = not acks or not size
                completed = not invalid_terminal_counters and acks == size
              end

              if completed then
                local completed_at = nil
                if redis.call('TYPE', KEYS[21]).ok == 'string' then
                  completed_at = tonumber(redis.call('GET', KEYS[21]))
                end
                if completed_at then
                  local redis_time = redis.call('TIME')
                  local now = tonumber(redis_time[1]) + tonumber(redis_time[2]) / 1000000
                  if now - completed_at < tonumber(ARGV[5]) then
                    return {0, current_generation, -1, {}, {}}
                  end
                else
                  invalid_active_state = true
                end
              elseif invalid_terminal_counters then
                invalid_active_state = true
              else
                return {0, current_generation, -1, {}, {}}
              end
            end

            local mode = 0 -- new run
            local previous_failures = {}
            local previous_errors = {}

            if stalled or invalid_active_state then
              mode = 2 -- fail-closed full rerun
            elseif existing_stat_count == 10 then
              local stat_values = {}
              local numeric_stats = true
              for key_index = 7, 16 do
                local key_type = redis.call('TYPE', KEYS[key_index]).ok
                local value = nil
                if key_type == 'string' then
                  value = tonumber(redis.call('GET', KEYS[key_index]))
                end
                if not value then
                  numeric_stats = false
                else
                  stat_values[#stat_values + 1] = value
                end
              end

              if not numeric_stats then
                mode = 2
              else
                local failures = stat_values[4]
                local errors = stat_values[5]
                local acks = stat_values[9]
                local size = stat_values[10]
                local max_failures = tonumber(ARGV[3])

                if truncated then
                  mode = 3 -- intentionally aborted at max_failures
                elseif acks == size then
                  if redis.call('EXISTS', KEYS[4]) == 0 then
                    mode = 2
                  else
                    previous_failures = redis.call('LRANGE', KEYS[18], 0, -1)
                    previous_errors = redis.call('LRANGE', KEYS[19], 0, -1)
                    if #previous_failures ~= failures or #previous_errors ~= errors then
                      mode = 2
                    else
                      mode = 1 -- valid selective retry
                    end
                  end
                elseif max_failures and failures + errors >= max_failures then
                  mode = 3
                else
                  mode = 2
                end
              end
            elseif existing_stat_count > 0 then
              mode = 2
            else
              -- Auxiliary state without statistics is an abandoned/corrupt run,
              -- not a genuinely new run ID. The generation token is excluded
              -- because it intentionally survives cleanup until the shared TTL.
              local auxiliary_count = redis.call(
                'EXISTS', KEYS[3], KEYS[4], KEYS[5], KEYS[6], KEYS[17], KEYS[18], KEYS[19], KEYS[20], KEYS[21]
              )
              if auxiliary_count > 0 then
                mode = 2
              end
            end

            -- No active attempt reaches here. A random token never repeats after
            -- expiry/eviction, so old workers cannot regain authority over a new
            -- attempt. All destructive changes and group creation are atomic.
            redis.call('DEL', KEYS[1])
            if mode == 2 then
              for key_index = 3, 21 do
                redis.call('DEL', KEYS[key_index])
              end
              previous_failures = {}
              previous_errors = {}
            else
              redis.call('DEL', KEYS[4], KEYS[5], KEYS[21])
              if mode == 1 or mode == 3 then
                redis.call('SET', KEYS[15], 0)
                redis.call('SET', KEYS[16], 0)
              else
                redis.call('DEL', KEYS[15], KEYS[16])
              end
              if mode == 3 then
                redis.call('SET', KEYS[20], 1, 'EX', ARGV[2])
              end
            end

            local generation = ARGV[4]
            redis.call('SET', KEYS[2], generation, 'EX', ARGV[2])
            local group_name = ARGV[1] .. '-' .. generation
            redis.call('XGROUP', 'CREATE', KEYS[1], group_name, '0', 'MKSTREAM')
            redis.call('EXPIRE', KEYS[1], ARGV[2])
            redis.call('SET', KEYS[5], 0, 'EX', ARGV[2])
            return {1, generation, mode, previous_failures, previous_errors}
          LUA
        end

        sig { returns(String) }
        def commit_results_script
          @commit_results_script ||= redis.script(:load, <<~LUA)
            local result_count = tonumber(ARGV[3])
            local expected_generation = ARGV[4]
            local argument_index = 5
            local commit_results = {}
            -- runs, assertions, passes, failures, errors, skips, requeues,
            -- discards, acks, size
            local deltas = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0}

            -- Every statistics key is created before any stream entries are
            -- published. Refuse to recreate missing state as zero: doing so can
            -- make an incomplete run look complete when both acks and size become
            -- 0. This preflight occurs before any write because Redis does not
            -- roll back earlier script writes when a later command errors.
            local current_generation = redis.call('GET', KEYS[19])
            if not current_generation then
              return redis.error_reply('COORDINATORSTATE missing required key ' .. KEYS[19])
            elseif current_generation ~= expected_generation then
              return redis.error_reply('STALEATTEMPT expected generation ' .. expected_generation)
            end

            if redis.call('TYPE', KEYS[1]).ok ~= 'stream' then
              return redis.error_reply('COORDINATORSTREAM missing or invalid key ' .. KEYS[1])
            end
            local groups = redis.pcall('XINFO', 'GROUPS', KEYS[1])
            local group_exists = false
            if not groups.err then
              for _, group in ipairs(groups) do
                for field_index = 1, #group, 2 do
                  if group[field_index] == 'name' and group[field_index + 1] == ARGV[1] then
                    group_exists = true
                  end
                end
              end
            end
            if not group_exists then
              return redis.error_reply('COORDINATORSTREAM missing consumer group ' .. ARGV[1])
            end

            local retry_type = redis.call('TYPE', KEYS[2]).ok
            if retry_type ~= 'none' and retry_type ~= 'set' then
              return redis.error_reply('COORDINATORSTATE invalid retry set type')
            end
            for list_index = 13, 15 do
              local list_type = redis.call('TYPE', KEYS[list_index]).ok
              if list_type ~= 'none' and list_type ~= 'list' then
                return redis.error_reply('COORDINATORSTATE invalid result list type')
              end
            end

            local max_safe_integer = 9007199254740991
            local stat_values = {}
            for stat_index = 1, 10 do
              local stat_key = KEYS[stat_index + 2]
              if redis.call('TYPE', stat_key).ok ~= 'string' then
                return redis.error_reply('COORDINATORSTATE missing or invalid key ' .. stat_key)
              end
              local validation = redis.pcall('INCRBY', stat_key, 0)
              if type(validation) == 'table' and validation.err then
                return redis.error_reply('COORDINATORSTATE invalid required key ' .. stat_key)
              end
              local value = tonumber(validation)
              if math.abs(value) > max_safe_integer then
                return redis.error_reply('COORDINATORSTATE unsafe statistic value ' .. stat_key)
              end
              stat_values[stat_index] = value
            end

            local allowed_result_types = {
              passed = true, failed = true, error = true, skipped = true,
              discarded = true, requeued = true
            }
            local validation_index = argument_index
            local assertion_total = 0
            for _ = 1, result_count do
              local result_type = ARGV[validation_index + 1]
              local assertions = tonumber(ARGV[validation_index + 4])
              if not allowed_result_types[result_type] or not assertions or assertions % 1 ~= 0 then
                return redis.error_reply('COORDINATORSTATE invalid result payload')
              end
              assertion_total = assertion_total + assertions
              validation_index = validation_index + 5
            end
            local maximum_deltas = {
              result_count, assertion_total, result_count, result_count, result_count,
              result_count, result_count, result_count, result_count, 0
            }
            for stat_index = 1, 10 do
              if math.abs(stat_values[stat_index]) + math.abs(maximum_deltas[stat_index]) > max_safe_integer then
                return redis.error_reply('COORDINATORSTATE unsafe statistic delta')
              end
            end

            for result_index = 1, result_count do
              local entry_id = ARGV[argument_index]
              local result_type = ARGV[argument_index + 1]
              local attempt_id = ARGV[argument_index + 2]
              local identifier = ARGV[argument_index + 3]
              local assertions = tonumber(ARGV[argument_index + 4])
              argument_index = argument_index + 5

              local committed
              if result_type == 'requeued' then
                committed = redis.call('SADD', KEYS[2], attempt_id)
                deltas[7] = deltas[7] + 1
              else
                committed = redis.call('XACK', KEYS[1], ARGV[1], entry_id)
                if committed == 1 then
                  deltas[9] = deltas[9] + 1
                  if result_type == 'passed' then
                    deltas[3] = deltas[3] + 1
                  elseif result_type == 'failed' then
                    deltas[4] = deltas[4] + 1
                    redis.call('LPUSH', KEYS[14], identifier)
                  elseif result_type == 'error' then
                    deltas[5] = deltas[5] + 1
                    redis.call('LPUSH', KEYS[15], identifier)
                  elseif result_type == 'skipped' then
                    deltas[6] = deltas[6] + 1
                    redis.call('LPUSH', KEYS[13], identifier)
                  elseif result_type == 'discarded' then
                    deltas[8] = deltas[8] + 1
                  end
                else
                  -- Another worker already ACKed this entry, so the local result
                  -- will be reported as discarded.
                  deltas[8] = deltas[8] + 1
                end
              end

              deltas[1] = deltas[1] + 1
              deltas[2] = deltas[2] + assertions
              commit_results[result_index] = committed
            end

            local reply = commit_results
            for stat_index = 1, 10 do
              reply[result_count + stat_index] = redis.call('INCRBY', KEYS[stat_index + 2], deltas[stat_index])
            end

            local updated_acks = reply[result_count + 9]
            local updated_size = reply[result_count + 10]
            if updated_acks == updated_size and redis.call('EXISTS', KEYS[16]) == 1 then
              local redis_time = redis.call('TIME')
              local completed_at = redis_time[1] .. '.' .. redis_time[2]
              redis.call('SET', KEYS[21], completed_at, 'EX', ARGV[2])
            end

            for key_index = 1, #KEYS do
              redis.call('EXPIRE', KEYS[key_index], ARGV[2])
            end

            return reply
          LUA
        end

        sig { returns(String) }
        def adjust_results_script
          @adjust_results_script ||= redis.script(:load, <<~LUA)
            local current_generation = redis.call('GET', KEYS[1])
            if not current_generation then
              return redis.error_reply('COORDINATORSTATE missing required key ' .. KEYS[1])
            elseif current_generation ~= ARGV[1] then
              return redis.error_reply('STALEATTEMPT expected generation ' .. ARGV[1])
            end

            local stream_type = redis.call('TYPE', KEYS[2]).ok
            local retry_type = redis.call('TYPE', KEYS[3]).ok
            if stream_type ~= 'stream' or (retry_type ~= 'none' and retry_type ~= 'set') then
              return redis.error_reply('COORDINATORSTATE invalid run key type')
            end
            for list_index = 18, 20 do
              local list_type = redis.call('TYPE', KEYS[list_index]).ok
              if list_type ~= 'none' and list_type ~= 'list' then
                return redis.error_reply('COORDINATORSTATE invalid result list type')
              end
            end

            local max_safe_integer = 9007199254740991
            for stat_index = 1, 10 do
              local stat_key = KEYS[stat_index + 7]
              local stat_type = redis.call('TYPE', stat_key).ok
              if stat_type ~= 'none' and stat_type ~= 'string' then
                return redis.error_reply('COORDINATORSTATE invalid required key ' .. stat_key)
              elseif stat_type == 'none' and ARGV[4] ~= '1' then
                return redis.error_reply('COORDINATORSTATE missing required key ' .. stat_key)
              end
              local current_value = 0
              if stat_type == 'string' then
                local validation = redis.pcall('INCRBY', stat_key, 0)
                if type(validation) == 'table' and validation.err then
                  return redis.error_reply('COORDINATORSTATE invalid required key ' .. stat_key)
                end
                current_value = tonumber(validation)
              end
              local delta = tonumber(ARGV[stat_index + 4])
              if not delta or delta % 1 ~= 0 or math.abs(current_value + delta) > max_safe_integer then
                return redis.error_reply('COORDINATORSTATE unsafe statistic value ' .. stat_key)
              end
            end

            if ARGV[3] == '1' then
              redis.call('DEL', KEYS[19], KEYS[20])
            end
            local reply = {}
            for stat_index = 1, 10 do
              reply[stat_index] = redis.call('INCRBY', KEYS[stat_index + 7], ARGV[stat_index + 4])
            end
            for key_index = 1, #KEYS do
              redis.call('EXPIRE', KEYS[key_index], ARGV[2])
            end
            return reply
          LUA
        end

        sig { returns(String) }
        def publish_tests_script
          @publish_tests_script ||= redis.script(:load, <<~LUA)
            local current_generation = redis.call('GET', KEYS[1])
            if not current_generation then
              return redis.error_reply('COORDINATORSTATE missing required key ' .. KEYS[1])
            elseif current_generation ~= ARGV[1] then
              return redis.error_reply('STALEATTEMPT expected generation ' .. ARGV[1])
            elseif redis.call('TYPE', KEYS[2]).ok ~= 'stream' then
              return redis.error_reply('COORDINATORSTREAM missing or invalid key ' .. KEYS[2])
            end

            local groups = redis.pcall('XINFO', 'GROUPS', KEYS[2])
            local group_exists = false
            if not groups.err then
              for _, group in ipairs(groups) do
                for field_index = 1, #group, 2 do
                  if group[field_index] == 'name' and group[field_index + 1] == ARGV[5] then
                    group_exists = true
                  end
                end
              end
            end
            if not group_exists then
              return redis.error_reply('COORDINATORSTREAM missing consumer group ' .. ARGV[5])
            end
            if redis.call('TYPE', KEYS[5]).ok ~= 'string' or redis.call('TYPE', KEYS[6]).ok ~= 'string' then
              return redis.error_reply('COORDINATORSTATE missing completion counters')
            end
            local acks = tonumber(redis.call('GET', KEYS[5]))
            local size = tonumber(redis.call('GET', KEYS[6]))
            if not acks or not size then
              return redis.error_reply('COORDINATORSTATE invalid completion counters')
            end

            local test_count = tonumber(ARGV[4])
            local argument_index = 6
            for _ = 1, test_count do
              redis.call(
                'XADD', KEYS[2], '*',
                'class_name', ARGV[argument_index],
                'method_name', ARGV[argument_index + 1]
              )
              argument_index = argument_index + 2
            end
            if ARGV[3] == '1' then
              redis.call('SET', KEYS[3], 1, 'EX', ARGV[2])
              if acks == size then
                local redis_time = redis.call('TIME')
                local completed_at = redis_time[1] .. '.' .. redis_time[2]
                redis.call('SET', KEYS[7], completed_at, 'EX', ARGV[2])
              end
            end
            for key_index = 1, #KEYS do
              redis.call('EXPIRE', KEYS[key_index], ARGV[2])
            end
            return test_count
          LUA
        end

        sig { returns(String) }
        def heartbeat_script
          @heartbeat_script ||= redis.script(:load, <<~LUA)
            local current_generation = redis.call('GET', KEYS[1])
            if not current_generation or current_generation ~= ARGV[1] then
              return 0
            end
            redis.call('INCR', KEYS[2])
            redis.call('EXPIRE', KEYS[1], ARGV[2])
            redis.call('EXPIRE', KEYS[2], ARGV[2])
            return 1
          LUA
        end

        sig { returns(String) }
        def mark_attempt_state_script
          @mark_attempt_state_script ||= redis.script(:load, <<~LUA)
            local current_generation = redis.call('GET', KEYS[1])
            if not current_generation or current_generation ~= ARGV[1] then
              return 0
            end
            redis.call('SET', KEYS[2], 1, 'EX', ARGV[2])
            redis.call('EXPIRE', KEYS[1], ARGV[2])
            return 1
          LUA
        end

        sig { returns(String) }
        def cleanup_script
          @cleanup_script ||= redis.script(:load, <<~LUA)
            local current_generation = redis.call('GET', KEYS[2])
            if not current_generation or current_generation ~= ARGV[1] then
              return 0
            end

            redis.pcall('XGROUP', 'DESTROY', KEYS[1], ARGV[2])
            redis.call('DEL', KEYS[1])
            return 1
          LUA
        end

        sig { returns(String) }
        def abort_script
          @abort_script ||= redis.script(:load, <<~LUA)
            local current_generation = redis.call('GET', KEYS[2])
            if current_generation and current_generation ~= ARGV[1] then
              return 0
            end

            redis.call('SET', KEYS[2], ARGV[1], 'EX', ARGV[3])
            redis.call('SET', KEYS[3], 1, 'EX', ARGV[3])
            redis.pcall('XGROUP', 'DESTROY', KEYS[1], ARGV[2])
            redis.call('DEL', KEYS[1])
            return 1
          LUA
        end

        sig do
          params(
            script_name: Symbol,
            keys: T::Array[String],
            argv: T::Array[T.untyped],
          ).returns(T.untyped)
        end
        def execute_script(script_name:, keys:, argv:)
          attempts = T.let(0, Integer)
          begin
            script_sha = case script_name
            when :register_consumergroup then register_consumergroup_script
            when :commit_results then commit_results_script
            when :cleanup then cleanup_script
            when :abort then abort_script
            when :adjust_results then adjust_results_script
            when :publish_tests then publish_tests_script
            when :heartbeat then heartbeat_script
            when :mark_attempt_state then mark_attempt_state_script
            else raise ArgumentError, "Unknown Redis script: #{script_name}"
            end
            redis.evalsha(script_sha, keys: keys, argv: argv)
          rescue Redis::CommandError => error
            if error.message.start_with?("NOSCRIPT") && attempts.zero?
              attempts += 1
              clear_script_cache(script_name)
              retry
            end
            raise
          end
        end

        sig { params(script_name: Symbol).void }
        def clear_script_cache(script_name)
          case script_name
          when :register_consumergroup then @register_consumergroup_script = nil
          when :commit_results then @commit_results_script = nil
          when :cleanup then @cleanup_script = nil
          when :abort then @abort_script = nil
          when :adjust_results then @adjust_results_script = nil
          when :publish_tests then @publish_tests_script = nil
          when :heartbeat then @heartbeat_script = nil
          when :mark_attempt_state then @mark_attempt_state_script = nil
          else raise ArgumentError, "Unknown Redis script: #{script_name}"
          end
        end

        sig { params(block: Integer).returns(T::Array[EnqueuedRunnable]) }
        def claim_fresh_runnables(block:)
          result = redis.xreadgroup(
            group_name,
            configuration.worker_id,
            stream_key,
            ">",
            block: block,
            count: configuration.test_batch_size,
          )
          claims = result.fetch(stream_key, [])
          @combined_results = nil if claims.any?
          EnqueuedRunnable.from_redis_stream_claim(claims, configuration: configuration)
        end

        sig do
          params(
            pending_messages: T::Hash[String, PendingExecution],
            max_idle_time_ms: Integer,
          ).returns(T::Array[EnqueuedRunnable])
        end
        def xclaim_messages(pending_messages, max_idle_time_ms:)
          return [] if pending_messages.empty?

          claimed = redis.xclaim(
            stream_key,
            group_name,
            configuration.worker_id,
            max_idle_time_ms,
            pending_messages.keys,
          )

          EnqueuedRunnable.from_redis_stream_claim(claimed, pending_messages, configuration: configuration)
        end

        sig { returns(T::Array[EnqueuedRunnable]) }
        def claim_stale_runnables
          # Every test is allowed to take test_timeout_seconds. Because we process tests in
          # batches, they should never be pending for TEST_TIMEOUT_SECONDS * BATCH_SIZE seconds.
          # So, only try to claim messages older than that, with a bit of jitter.
          max_idle_time_ms = Integer(configuration.test_timeout_seconds * configuration.test_batch_size * 1000)
          max_idle_time_ms_with_jitter = max_idle_time_ms * rand(1.0...1.2)

          # Find all the pending messages to see if we want to attenpt to claim some.
          pending = redis.xpending(stream_key, group_name, "-", "+", configuration.test_batch_size)
          return [] if pending.empty?

          active_consumers = Set[configuration.worker_id]

          stale_messages = {}
          active_messages = {}
          pending.each do |msg|
            message = PendingExecution.from_xpending(msg)
            if message.elapsed_time_ms < max_idle_time_ms_with_jitter
              active_consumers << message.worker_id
              active_messages[message.entry_id] = message
            else
              stale_messages[message.entry_id] = message
            end
          end

          # If we only have evidence of one active consumer based on the pending message,
          # we will query Redis for all consumers to make sure we have full data.
          # We can skip this if we already know that there is more than one active one.
          if active_consumers.size == 1
            begin
              redis.xinfo("consumers", stream_key, group_name).each do |consumer|
                if consumer.fetch("idle") < max_idle_time_ms
                  active_consumers << consumer.fetch("name")
                end
              end
            rescue Redis::CommandError
              # This command can fail, specifically during the cleanup phase at the end
              # of a build, when another worker has removed the stream key already.
            end
          end

          # Now, see if we want to claim any stale messages. If we are the only active
          # consumer, we want to claim our own messages as well as messgaes from other
          # (stale) consumers. If there are multiple active consumers, we are going to
          # let another consumer claim our own messages.
          if active_consumers.size > 1
            stale_messages.reject! { |_key, message| message.worker_id == configuration.worker_id }
          end

          unless stale_messages.empty?
            # When we have to reclaim stale tests, those test are potentially too slow
            # to run inside the test timeout. We only claim one timed out test at a time in order
            # to prevent the exact same batch from being too slow on repeated attempts,
            # which would cause us to mark all the tests in that batch as failed.
            #
            # This has the side effect that for a retried test, the test timeout
            # will be TEST_TIMEOUT_SECONDS * BATCH_SIZE in practice. This gives us a higher
            # likelihood that the test will pass if the batch size > 1.
            stale_messages = stale_messages.slice(stale_messages.keys.first)

            enqueued_runnables = xclaim_messages(stale_messages, max_idle_time_ms: max_idle_time_ms)
            reclaimed_timeout_tests.merge(enqueued_runnables)
            return enqueued_runnables
          end

          # Now, see if we want to claim any failed tests to retry. Again, if we are the only
          # active consumer, we want to claim our own messages as well as messgaes from other
          # (stale) consumers. If there are multiple active consumers, we are going to let
          # another consumer claim our own messages.
          if active_consumers.size > 1
            active_messages.reject! { |_key, message| message.worker_id == configuration.worker_id }
          end

          # For all the active messages, we can check whether they are marked for a retry by
          # trying to remove the test from the retry set set in Redis. Only one worker will be
          # able to remove the entry from the set, so only one worker will end up trying to
          # claim the test for the next attempt.
          #
          # We use `redis.multi` so we only need one round-trip for the entire list. Note that
          # this is not an atomic operation with the XCLAIM call. This is OK, because the retry
          # set is only there to speed things up and prevent us from having to wait for the test
          # timeout. If the worker crashes between removing an item from the retry setm the test
          # will eventually be picked up by another worker.
          messages_in_retry_set = {}
          redis.multi do |pipeline|
            active_messages.each do |key, message|
              messages_in_retry_set[key] = pipeline.srem(key("retry_set"), [message.attempt_id])
            end
          end

          # Now, we only select the messages that were on the retry set, and try to claim them.
          active_messages.keep_if { |key, _value| messages_in_retry_set.fetch(key).value > 0 }
          enqueued_runnables = xclaim_messages(active_messages, max_idle_time_ms: 0)
          reclaimed_failed_tests.merge(enqueued_runnables)
          enqueued_runnables
        end

        sig { params(tests: T::Array[Minitest::Runnable]).void }
        def publish_tests(tests)
          generation = T.must(@attempt_generation)
          batches = tests.each_slice(PRODUCTION_BATCH_SIZE)
          batches = [[]].each if tests.empty?
          batches.each_with_index do |batch, index|
            final_batch = tests.empty? || (index + 1) * PRODUCTION_BATCH_SIZE >= tests.length
            argv = T.let(
              [generation, configuration.key_ttl_seconds, final_batch ? 1 : 0, batch.length, group_name],
              T::Array[T.untyped],
            )
            batch.each do |test|
              argv << T.must(test.class.name)
              argv << test.name
            end
            execute_script(
              script_name: :publish_tests,
              keys: [
                key("attempt_generation"),
                stream_key,
                key("production_complete"),
                key("production_heartbeat"),
                key("acks"),
                key("size"),
                key("completed_at"),
              ],
              argv: argv,
            )
          end
          @production_complete = true
        end

        sig { void }
        def mark_run_truncated
          generation = T.must(@attempt_generation)
          execute_script(
            script_name: :mark_attempt_state,
            keys: [key("attempt_generation"), key("truncated")],
            argv: [generation, configuration.key_ttl_seconds],
          )
        end

        sig { returns(Thread) }
        def start_production_heartbeat
          generation = T.must(@attempt_generation)
          interval = [configuration.stall_timeout_seconds / 2, MAX_PRODUCTION_HEARTBEAT_INTERVAL_SECONDS].min
          Thread.new do
            Thread.current.report_on_exception = false
            loop do
              sleep(interval)
              updated = execute_script(
                script_name: :heartbeat,
                keys: [key("attempt_generation"), key("production_heartbeat")],
                argv: [generation, configuration.key_ttl_seconds],
              )
              break unless updated == 1
            end
          end
        end

        sig { params(thread: Thread).void }
        def stop_production_heartbeat(thread)
          thread.kill
          thread.join
        end

        sig { params(results: ResultAggregate).returns(T::Boolean) }
        def run_complete?(results)
          results.complete? && production_complete?
        end

        sig { returns(T::Boolean) }
        def production_complete?
          @production_complete ||= redis.exists?(key("production_complete"))
        end

        sig { returns(T.nilable(Integer)) }
        def current_production_heartbeat
          value = redis.get(key("production_heartbeat"))
          value.nil? ? nil : Integer(value)
        end

        # Read all the state needed to distinguish a legitimately slow pending
        # test from a drained queue whose completion counters can no longer agree.
        # This deliberately bypasses `@combined_results`, which is memoized.
        sig { returns(StallProbe) }
        def probe_stall
          counters, pending_summary, groups, stream_info = redis.pipelined do |pipeline|
            pipeline.mget(key("acks"), key("size"), key("production_complete"), key("production_heartbeat"))
            pipeline.xpending(stream_key, group_name)
            pipeline.xinfo("groups", stream_key)
            pipeline.xinfo("stream", stream_key)
          end

          raw_acks, raw_size, raw_production_complete, raw_production_heartbeat = T.unsafe(counters)
          group = T.unsafe(groups).find { |candidate| candidate.fetch("name") == group_name }
          raw_lag = group&.fetch("lag", nil)
          lag = raw_lag.nil? ? nil : Integer(raw_lag)

          # Redis added the explicit group lag field in version 7. On older
          # versions, equal delivery and stream IDs still prove that there are no
          # undelivered entries because this coordinator never trims the stream.
          if lag.nil? && group && group.fetch("last-delivered-id") == T.unsafe(stream_info).fetch("last-generated-id")
            lag = 0
          end

          StallProbe.new(
            acks: raw_acks.nil? ? nil : Integer(raw_acks),
            size: raw_size.nil? ? nil : Integer(raw_size),
            pending_count: Integer(T.unsafe(pending_summary).fetch("size")),
            lag: lag,
            production_complete: !raw_production_complete.nil?,
            production_heartbeat: raw_production_heartbeat.nil? ? nil : Integer(raw_production_heartbeat),
          )
        end

        sig { params(probe: StallProbe).void }
        def abort_stalled_run(probe)
          abort_with_diagnostic(format_stall_diagnostic(probe))
        end

        sig { params(error: Redis::CommandError).void }
        def handle_coordinator_state_error(error)
          return if attempt_superseded?

          @combined_results = nil
          results = combined_results
          mandatory_state_missing = error.message.start_with?("COORDINATORSTATE")
          return if !mandatory_state_missing && (run_complete?(results) || results.abort?)

          state = "run_id=#{configuration.run_id} worker_id=#{configuration.worker_id} " \
            "acks=#{results.acks} size=#{results.size} redis_error=#{error.message.inspect}"
          diagnostic = <<~DIAGNOSTIC
            ERROR: minitest-distributed lost required Redis coordinator state and aborted the run.
            #{state}
            The run is incomplete, so this was not normal cleanup. A run key may have expired, been evicted, or been deleted.
          DIAGNOSTIC
          abort_with_diagnostic(diagnostic)
        end

        sig { returns(T::Boolean) }
        def attempt_superseded?
          attempt_generation = @attempt_generation
          return false unless attempt_generation

          current_generation = redis.get(key("attempt_generation"))
          return false if current_generation.nil?

          current_generation != attempt_generation
        end

        sig { params(diagnostic: String).void }
        def abort_with_diagnostic(diagnostic)
          generation = T.must(@attempt_generation)
          applied = execute_script(
            script_name: :abort,
            keys: [stream_key, key("attempt_generation"), key("stalled")],
            argv: [generation, group_name, configuration.key_ttl_seconds],
          )
          return unless applied == 1

          @aborted = true
          @stall_diagnostic = diagnostic
          emit_message(diagnostic)
        end

        sig { params(probe: StallProbe).returns(String) }
        def format_stall_diagnostic(probe)
          <<~DIAGNOSTIC
            ERROR: minitest-distributed detected inconsistent Redis coordinator state and aborted the run.
            #{format_probe_state(probe)}
            The consumer group has no pending or undelivered tests, but acks does not equal size.
            One or more coordinator keys may have been evicted or deleted; the run cannot make further progress.
          DIAGNOSTIC
        end

        sig { params(probe: StallProbe).returns(String) }
        def format_pending_stall_warning(probe)
          timeout = format("%g", configuration.stall_timeout_seconds)
          reclaim_after = format("%g", configuration.test_timeout_seconds * configuration.test_batch_size)
          <<~WARNING
            WARNING: minitest-distributed has made no progress for #{timeout}s, but Redis still has pending tests.
            #{format_probe_state(probe)}
            The worker will keep waiting; pending tests become reclaimable after approximately #{reclaim_after}s.
          WARNING
        end

        sig { params(probe: StallProbe).returns(String) }
        def format_probe_state(probe)
          "run_id=#{configuration.run_id} worker_id=#{configuration.worker_id} " \
            "acks=#{format_probe_value(probe.acks)} size=#{format_probe_value(probe.size)} " \
            "pending=#{probe.pending_count} lag=#{format_probe_value(probe.lag)} " \
            "production_complete=#{probe.production_complete} " \
            "production_heartbeat=#{format_probe_value(probe.production_heartbeat)}"
        end

        sig { params(value: T.nilable(Integer)).returns(String) }
        def format_probe_value(value)
          value.nil? ? "missing" : value.to_s
        end

        sig { params(message: String).void }
        def emit_message(message)
          (@output || $stderr).puts(message)
        end

        sig { returns(Float) }
        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
        end

        sig { void }
        def cleanup
          generation = T.must(@attempt_generation)
          execute_script(
            script_name: :cleanup,
            keys: [stream_key, key("attempt_generation")],
            argv: [generation, group_name],
          )
        end

        # The keys the coordinator writes for a run, other than the stream, are plain
        # counters, lists and sets that intentionally survive `cleanup`: retry mode and
        # the summary reporters read them after the stream is gone. Nothing ever removes
        # them, so a coordinator accumulates roughly a dozen keys per run, forever.
        #
        # That matters most where the coordinator is a shared Redis running an
        # `allkeys-lru` eviction policy at maxmemory, because LRU is then free to evict
        # the keys of a *running* build. Losing one is silent and unrecoverable: a run
        # only finishes when `acks == size`, so every worker keeps polling a drained
        # queue, printing nothing, until CI kills it.
        #
        # An expiry does not stop an eviction, and is not claimed to. It bounds what a
        # finished run leaves behind, which is the part this gem owns.
        STATS_KEY_NAMES = T.let(
          ["runs", "assertions", "passes", "failures", "errors", "skips", "requeues", "discards", "acks", "size"].freeze,
          T::Array[String],
        )
        private_constant :STATS_KEY_NAMES

        LIST_KEY_RESULT_TYPES = T.let(
          [ResultType::Skipped, ResultType::Failed, ResultType::Error].freeze,
          T::Array[ResultType],
        )
        private_constant :LIST_KEY_RESULT_TYPES

        sig do
          params(
            results: ResultAggregate,
            clear_retry_lists: T::Boolean,
            allow_missing_stats: T::Boolean,
          ).void
        end
        def adjust_combined_results(results, clear_retry_lists: false, allow_missing_stats: false)
          generation = T.must(@attempt_generation)
          keys = [
            key("attempt_generation"),
            stream_key,
            key("retry_set"),
            key("production_complete"),
            key("production_heartbeat"),
            key("stalled"),
            key("truncated"),
          ]
          keys.concat(STATS_KEY_NAMES.map { |name| key(name) })
          keys.concat(LIST_KEY_RESULT_TYPES.map { |result_type| list_key(result_type.serialize) })
          keys << key("completed_at")
          argv = [
            generation,
            configuration.key_ttl_seconds,
            clear_retry_lists ? 1 : 0,
            allow_missing_stats ? 1 : 0,
            results.runs,
            results.assertions,
            results.passes,
            results.failures,
            results.errors,
            results.skips,
            results.requeues,
            results.discards,
            results.acks,
            results.size,
          ]
          updated = execute_script(script_name: :adjust_results, keys: keys, argv: argv)
          update_combined_results(T.cast(updated, T::Array[Integer]))
        end

        sig { params(name: String).returns(String) }
        def key(name)
          "minitest/#{configuration.run_id}/#{name}"
        end

        sig { params(name: String).returns(String) }
        def list_key(name)
          key("#{name}_list")
        end

        sig do
          params(
            results: T::Array[[EnqueuedRunnable, Minitest::Result]],
          ).returns(T::Array[EnqueuedRunnable::Result])
        end
        def commit_results(results)
          arguments = T.let(
            [group_name, configuration.key_ttl_seconds, results.size, T.must(@attempt_generation)],
            T::Array[T.untyped],
          )
          results.each do |enqueued_runnable, result|
            arguments.push(
              enqueued_runnable.entry_id,
              ResultType.of(result).serialize,
              enqueued_runnable.attempt_id,
              enqueued_runnable.identifier,
              result.assertions,
            )
          end

          keys = [stream_key, key("retry_set")]
          keys.concat(STATS_KEY_NAMES.map { |name| key(name) })
          keys.concat(LIST_KEY_RESULT_TYPES.map { |result_type| list_key(result_type.serialize) })
          keys.push(
            key("production_complete"),
            key("stalled"),
            key("production_heartbeat"),
            key("attempt_generation"),
            key("truncated"),
            key("completed_at"),
          )

          response = T.unsafe(execute_script(script_name: :commit_results, keys: keys, argv: arguments))
          commit_statuses = T.cast(response.take(results.size), T::Array[Integer])
          update_combined_results(T.cast(response.drop(results.size), T::Array[Integer]))
          build_runnable_results(results, commit_statuses)
        rescue Redis::CommandError => error
          cleanup_race_error = error.message.start_with?("NOGROUP", "COORDINATORSTREAM") ||
            error.message.include?("no such key")
          raise unless cleanup_race_error

          # Another worker may have completed and cleaned up while this batch was
          # running. Preserve the reporter contract by presenting these local
          # results as uncommitted/discarded, but only when fresh counters prove
          # the shared run is already terminal. Incomplete state is handled by
          # consume's fail-closed coordinator-state path.
          @combined_results = nil
          terminal_results = combined_results
          raise unless run_complete?(terminal_results) || terminal_results.abort?

          build_runnable_results(results, Array.new(results.size, 0))
        end

        sig do
          params(
            results: T::Array[[EnqueuedRunnable, Minitest::Result]],
            commit_statuses: T::Array[Integer],
          ).returns(T::Array[EnqueuedRunnable::Result])
        end
        def build_runnable_results(results, commit_statuses)
          results.each_with_index.map do |(enqueued_runnable, result), index|
            commit = if commit_statuses.fetch(index) == 1
              EnqueuedRunnable::Result::Commit.success
            else
              EnqueuedRunnable::Result::Commit.failure
            end
            enqueued_runnable.commit_result(result) { |_result_to_commit| commit }
          end
        end

        sig { params(updated: T::Array[Integer]).void }
        def update_combined_results(updated)
          @combined_results = ResultAggregate.new(
            max_failures: configuration.max_failures,
            runs: updated.fetch(0),
            assertions: updated.fetch(1),
            passes: updated.fetch(2),
            failures: updated.fetch(3),
            errors: updated.fetch(4),
            skips: updated.fetch(5),
            requeues: updated.fetch(6),
            discards: updated.fetch(7),
            acks: updated.fetch(8),
            size: updated.fetch(9),
          )
        end

        sig { params(batch: T::Array[EnqueuedRunnable], reporter: AbstractReporter).void }
        def process_batch(batch, reporter)
          return 0 if batch.empty?

          local_results.size += batch.size

          # Call `prerecord` on the recorder for all tests in the batch, and run them.
          results = batch.map do |enqueued_runnable|
            reporter.prerecord(enqueued_runnable.runnable_class, enqueued_runnable.method_name)
            [enqueued_runnable, enqueued_runnable.run]
          end

          # XACK/SADD, result-list writes, statistics and expiries are committed
          # atomically so a diagnostic probe cannot observe a valid half-commit.
          runnable_results = commit_results(results)
          runnable_results.each do |runnable_result|
            # Complete the reporter contract by calling `record` with the result.
            reporter.record(runnable_result.committed_result)

            # The combined statistics were updated by `commit_results`; only this
            # worker's local statistics remain to be recorded here.
            local_results.update_with_result(runnable_result)
          end
        end

        sig { returns(T.nilable(Logger)) }
        def logger
          return unless (log_path = ENV["MINITEST_DISTRIBUTED_REDIS_LOG"])

          @logger ||= T.let(Logger.new(log_path), T.nilable(Logger))
        end

        sig { params(backoff: Integer).returns(Integer) }
        def next_backoff(backoff)
          [backoff << 1, MAX_BACKOFF].min
        end

        BASE_GROUP_NAME = "minitest-distributed"
        private_constant :BASE_GROUP_NAME

        # Confirm a drained mismatch because the diagnostic probe itself uses
        # multiple pipelined Redis commands and is not an atomic snapshot.
        STALL_CONFIRMATION_SECONDS = 30.0
        private_constant :STALL_CONFIRMATION_SECONDS

        MAX_PRODUCTION_HEARTBEAT_INTERVAL_SECONDS = 30.0
        private_constant :MAX_PRODUCTION_HEARTBEAT_INTERVAL_SECONDS

        COMPLETED_ATTEMPT_GRACE_SECONDS = 30.0
        private_constant :COMPLETED_ATTEMPT_GRACE_SECONDS

        PRODUCTION_BATCH_SIZE = 100
        private_constant :PRODUCTION_BATCH_SIZE

        INITIAL_BACKOFF = 10 # milliseconds
        private_constant :INITIAL_BACKOFF

        # Cap on the XREADGROUP BLOCK timeout used by `consume`. Reached after roughly
        # 9 consecutive empty iterations (10 ms * 2^9 = 5120 ms). Bounds the worst-case
        # time a worker can be unresponsive to `complete?` / `abort?` after the queue
        # is drained.
        MAX_BACKOFF = 5_000 # milliseconds
        private_constant :MAX_BACKOFF
      end
    end
  end
end
