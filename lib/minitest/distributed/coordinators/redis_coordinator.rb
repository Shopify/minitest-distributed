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

        class CoordinatorStateError < StandardError; end
        private_constant :CoordinatorStateError

        class StallProbe < T::Struct
          const :acks, T.nilable(Integer)
          const :size, T.nilable(Integer)
          const :pending_count, Integer
          const :lag, T.nilable(Integer)
          const :production_complete, T::Boolean
          const :production_heartbeat, T.nilable(Integer)
          const :invalid_values, T::Array[String]
        end
        private_constant :StallProbe

        class HeartbeatControl < T::Struct
          const :mutex, Mutex, factory: -> { Mutex.new }
          const :condition, ConditionVariable, factory: -> { ConditionVariable.new }
          prop :stop_requested, T::Boolean, default: false
        end
        private_constant :HeartbeatControl

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
          @read_results_script = T.let(nil, T.nilable(String))
          @reset_results_script = T.let(nil, T.nilable(String))
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
          @production_heartbeat_error = T.let(nil, T.nilable(StandardError))
          @production_heartbeat_control = T.let(nil, T.nilable(HeartbeatControl))
          @mutating_script_mutex = T.let(Mutex.new, Mutex)
          @local_results = T.let(ResultAggregate.new, ResultAggregate)
          @combined_results = T.let(nil, T.nilable(ResultAggregate))
          @combined_results_production_complete = T.let(nil, T.nilable(T::Boolean))
          @attempt_truncated = T.let(false, T::Boolean)
          @truncated_follower = T.let(false, T::Boolean)
          @retry_refused_due_to_truncation = T.let(false, T::Boolean)
          @truncation_state_invalid = T.let(false, T::Boolean)
          @registration_rejected = T.let(false, T::Boolean)
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
            keys = STATS_KEY_NAMES.map { |name| key(name) }
            keys << key("production_complete")
            response = T.cast(
              execute_script(script_name: :read_results, keys: keys, argv: []),
              T::Array[T.untyped],
            )
            @combined_results_production_complete = response.fetch(0) == 1
            stats_as_string = response.drop(1)

            ResultAggregate.new(
              max_failures: configuration.max_failures,

              runs: Integer(stats_as_string.fetch(0).then { |value| value == "" ? 0 : value }),
              assertions: Integer(stats_as_string.fetch(1).then { |value| value == "" ? 0 : value }),
              passes: Integer(stats_as_string.fetch(2).then { |value| value == "" ? 0 : value }),
              failures: Integer(stats_as_string.fetch(3).then { |value| value == "" ? 0 : value }),
              errors: Integer(stats_as_string.fetch(4).then { |value| value == "" ? 0 : value }),
              skips: Integer(stats_as_string.fetch(5).then { |value| value == "" ? 0 : value }),
              requeues: Integer(stats_as_string.fetch(6).then { |value| value == "" ? 0 : value }),
              discards: Integer(stats_as_string.fetch(7).then { |value| value == "" ? 0 : value }),
              acks: Integer(stats_as_string.fetch(8).then { |value| value == "" ? 0 : value }),

              # Before the producer initializes counters, a sentinel prevents the
              # absent size from making an unpublished run appear complete.
              size: Integer(stats_as_string.fetch(9).then { |value| value == "" ? 2_147_483_647 : value }),
            )
          end
        rescue ArgumentError, TypeError => parse_error
          raise CoordinatorStateError, "invalid Redis aggregate: #{parse_error.message}"
        end

        sig { override.returns(T::Boolean) }
        def aborted?
          @aborted
        end

        sig { override.returns(T::Boolean) }
        def valid_combined_results?
          # Reporter success must be based on one fresh atomic snapshot. Counters
          # alone can look complete after production_complete is evicted.
          @combined_results = nil
          results = combined_results
          results.valid? && @combined_results_production_complete == true
        rescue Redis::BaseError, CoordinatorStateError
          false
        end

        sig { returns(T::Boolean) }
        def stalled?
          !stall_diagnostic.nil?
        end

        sig { returns(T::Boolean) }
        def registration_rejected?
          @registration_rejected
        end

        sig { returns(T::Boolean) }
        def retry_refused_due_to_truncation?
          @retry_refused_due_to_truncation
        end

        sig { returns(T::Boolean) }
        def current_attempt_truncated?
          @attempt_truncated
        end

        sig { returns(T::Boolean) }
        def truncation_state_invalid?
          @truncation_state_invalid
        end

        sig { override.params(test_selector: TestSelector).void }
        def produce(test_selector:)
          production_heartbeat_thread = T.let(nil, T.nilable(Thread))
          propagate_heartbeat_error = T.let(false, T::Boolean)

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
          registration_keys.push(
            key("truncated"),
            key("completed_at"),
            key("retry_snapshot_digest"),
            key("truncated_generation"),
            key("retention_ttl"),
          )
          registration = T.let(nil, T.untyped)
          registration_mode = T.let(-1, Integer)
          leader = T.let(false, T::Boolean)
          awaited_generation = T.let(nil, T.nilable(String))
          loop do
            registration = T.unsafe(execute_script(
              script_name: :register_consumergroup,
              keys: registration_keys,
              argv: [
                BASE_GROUP_NAME,
                configuration.key_ttl_seconds,
                configuration.max_failures || "",
                SecureRandom.uuid,
                configuration.completion_grace_seconds,
                awaited_generation || "",
              ],
            ))

            leader = registration.fetch(0) == 1
            @attempt_generation = String(registration.fetch(1))
            @group_name = "#{BASE_GROUP_NAME}-#{@attempt_generation}"
            registration_mode = Integer(registration.fetch(2))
            if registration_mode == -3
              @aborted = true
              @truncated_follower = true
              @retry_refused_due_to_truncation = true
            elsif registration_mode == -4
              @aborted = true
              @registration_rejected = true
              emit_message(<<~ERROR)
                ERROR: minitest-distributed rejected a Redis key TTL change for an existing run.
                run_id=#{configuration.run_id} worker_id=#{configuration.worker_id}
                Active workers must use the same key TTL, and later retries cannot decrease the retained TTL.
              ERROR
            elsif registration_mode == -5
              @aborted = true
              @truncation_state_invalid = true
              emit_message(<<~ERROR)
                ERROR: minitest-distributed cannot retry because the retained truncation fence is incomplete.
                run_id=#{configuration.run_id} worker_id=#{configuration.worker_id}
                The run remains failed; restore or expire its retained state before reusing this run ID.
              ERROR
            end
            break unless registration_mode == -2

            sleep(Float(registration.fetch(5)))
            awaited_generation = String(registration.fetch(1))
          end
          return unless leader

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
                test_identifiers_to_retry = T.let(previous_failures + previous_errors, T::Array[String])
                retry_tests = materialize_retry_tests(test_identifiers_to_retry)
                if retry_tests
                  total_failures = retry_tests.length
                  adjust_combined_results(
                    ResultAggregate.new(
                      size: total_failures,
                      failures: -previous_failures.length,
                      errors: -previous_errors.length,
                      requeues: total_failures,
                    ),
                    clear_retry_lists: true,
                  )
                  retry_tests
                else
                  emit_message(<<~WARNING)
                    WARNING: The previous attempt retained an invalid retry identifier.
                    Running the full test suite instead of a selective retry.
                  WARNING
                  tests_from_selector = test_selector.tests
                  reset_combined_results_for_full_rerun(size: tests_from_selector.size)
                  tests_from_selector
                end
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
              @retry_refused_due_to_truncation = true
              adjust_combined_results(ResultAggregate.new(size: 0))
              []
            else
              raise "Unknown Redis registration mode: #{registration_mode}"
            end,
            T::Array[Minitest::Runnable],
          )

          publish_tests(tests)
          propagate_heartbeat_error = true
        ensure
          if production_heartbeat_thread
            stop_production_heartbeat(
              production_heartbeat_thread,
              propagate_error: propagate_heartbeat_error,
            )
          end
        end

        # The loop intentionally keeps the stale/fresh claim and diagnostic state
        # transitions together so each iteration observes one coherent snapshot.
        # rubocop:disable Metrics/BlockNesting, Lint/RedundantCopDisableDirective
        sig { override.params(reporter: AbstractReporter).void }
        def consume(reporter:)
          return if @truncated_follower || @registration_rejected || @truncation_state_invalid

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
            # Other workers can advance or complete the run without touching this
            # process's memoized aggregate. Refresh once per polling iteration.
            @combined_results = nil

            # First, see if there are any pending tests from other workers to claim.
            stale_runnables = claim_stale_runnables
            process_batch(stale_runnables, reporter)
            break if commit_observed_truncation?

            # Then, try to process a regular batch of messages
            fresh_runnables = claim_fresh_runnables(block: exponential_backoff)
            process_batch(fresh_runnables, reporter)
            break if commit_observed_truncation?

            run_results = combined_results

            # If we have acked the same amount of tests as we were supposed to, the run
            # is complete and we can exit our loop. Generally, only one worker will detect
            # this condition. The other workers will quit their consumer loop because the
            # consumer group will be deleted by the first worker, and their Redis commands
            # will start to fail - see the rescue block below. Counters can be 0/0 before
            # an empty run finishes publishing, so production completion is also required.
            break if run_complete?(run_results)

            # We also abort a run if we reach the maximum number of failures.
            if run_results.abort? && !run_results.complete?
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

                if probe.invalid_values.any?
                  abort_with_diagnostic(<<~DIAGNOSTIC)
                    ERROR: minitest-distributed found invalid numeric Redis coordinator state.
                    #{format_probe_state(probe)}
                    Invalid values: #{probe.invalid_values.join(", ")}
                  DIAGNOSTIC
                  break
                end

                # Another worker may have completed the run while our memoized aggregate
                # was stale. Treat the fresh counters as authoritative.
                if probe.production_complete && !probe.acks.nil? && probe.acks == probe.size
                  # The probe checks completion/liveness fields only. Validate all
                  # retained statistics and the same-snapshot production marker
                  # before accepting terminal success.
                  terminal_results = combined_results
                  break if run_complete?(terminal_results)
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
            "WRONGTYPE",
            "COORDINATORSTATE",
            "COORDINATORSTREAM",
            "STALEATTEMPT",
            "COORDINATORCONFIG",
          ) || ce.message.include?("no such key")
          if coordinator_state_error
            # A normal cleanup and missing/evicted state can produce similar Redis
            # errors. Fresh counters distinguish a terminal run from data loss.
            handle_coordinator_state_error(ce)
            cleanup if stalled?
          else
            raise
          end
        rescue CoordinatorStateError => parse_error
          abort_with_diagnostic(<<~DIAGNOSTIC)
            ERROR: minitest-distributed could not parse Redis coordinator state.
            run_id=#{configuration.run_id} worker_id=#{configuration.worker_id}
            parse_error=#{parse_error.message.inspect}
          DIAGNOSTIC
          cleanup if stalled?
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
        def read_results_script
          @read_results_script ||= redis.script(:load, <<~LUA)
            -- KEYS: ten statistics followed by production_complete.
            local max_safe_integer = 9007199254740991
            local production_type = redis.call('TYPE', KEYS[11]).ok
            local production_complete = false
            if production_type == 'string' then
              if redis.call('GET', KEYS[11]) ~= '1' then
                return redis.error_reply('COORDINATORSTATE invalid production_complete marker')
              end
              production_complete = true
            elseif production_type ~= 'none' then
              return redis.error_reply('COORDINATORSTATE invalid production_complete type')
            end

            local values = {}
            local existing_count = 0
            for stat_index = 1, 10 do
              local stat_type = redis.call('TYPE', KEYS[stat_index]).ok
              if stat_type == 'none' then
                if production_complete then
                  return redis.error_reply('COORDINATORSTATE missing terminal statistic ' .. KEYS[stat_index])
                end
                values[stat_index] = ''
              elseif stat_type ~= 'string' then
                return redis.error_reply('COORDINATORSTATE invalid statistic type ' .. KEYS[stat_index])
              else
                local validation = redis.pcall('INCRBY', KEYS[stat_index], 0)
                if type(validation) == 'table' and validation.err then
                  return redis.error_reply('COORDINATORSTATE invalid statistic ' .. KEYS[stat_index])
                end
                local value = tonumber(validation)
                if not value or value < 0 or value > max_safe_integer then
                  return redis.error_reply('COORDINATORSTATE unsafe statistic ' .. KEYS[stat_index])
                end
                values[stat_index] = value
                existing_count = existing_count + 1
              end
            end

            if existing_count > 0 and existing_count < 10 then
              return redis.error_reply('COORDINATORSTATE partial aggregate statistics')
            elseif existing_count == 10 then
              local runs = values[1]
              local reported = values[3] + values[4] + values[5] + values[6]
              if values[9] > values[10] or runs < values[7] + values[8] or
                runs - values[7] - values[8] ~= reported then
                return redis.error_reply('COORDINATORSTATE inconsistent aggregate statistics')
              end
            end

            local reply = {production_complete and 1 or 0}
            for stat_index = 1, 10 do
              if values[stat_index] == '' then
                reply[#reply + 1] = ''
              else
                reply[#reply + 1] = values[stat_index]
              end
            end
            return reply
          LUA
        end

        sig { returns(String) }
        def register_consumergroup_script
          @register_consumergroup_script ||= redis.script(:load, <<~LUA)
            -- KEYS: stream, generation token, stalled, production_complete,
            -- production_heartbeat, retry_set, ten statistics, the
            -- skipped/failed/error lists, truncated, completed_at, then the
            -- completed retry-snapshot digest, truncating generation, and the
            -- monotonic retained-state TTL.
            local max_safe_integer = 9007199254740991
            local invalid_active_state = false
            local requested_ttl = tonumber(ARGV[2])
            local retention_type = redis.call('TYPE', KEYS[24]).ok
            local retained_ttl = nil
            if retention_type == 'string' then
              local validation = redis.pcall('INCRBY', KEYS[24], 0)
              if type(validation) == 'table' and validation.err then
                invalid_active_state = true
              else
                retained_ttl = tonumber(validation)
                if not retained_ttl or retained_ttl <= 0 then
                  invalid_active_state = true
                elseif requested_ttl < retained_ttl then
                  return {0, '', -4, {}, {}}
                end
              end
            elseif retention_type ~= 'none' then
              invalid_active_state = true
            end

            local stream_type = redis.call('TYPE', KEYS[1]).ok
            local stream_exists = stream_type == 'stream'
            if stream_type ~= 'none' and stream_type ~= 'stream' then
              invalid_active_state = true
            end

            local generation_type = redis.call('TYPE', KEYS[2]).ok
            local current_generation = nil
            if generation_type == 'string' then
              current_generation = redis.call('GET', KEYS[2])
            elseif generation_type ~= 'none' then
              invalid_active_state = true
            end

            local function read_marker(key)
              local marker_type = redis.call('TYPE', key).ok
              if marker_type == 'none' then
                return false, false
              elseif marker_type == 'string' and redis.call('GET', key) == '1' then
                return true, false
              end
              return false, true
            end

            local stalled, stalled_invalid = read_marker(KEYS[3])
            local production_complete, production_complete_invalid = read_marker(KEYS[4])
            local truncated, truncated_invalid = read_marker(KEYS[20])
            local truncated_generation_type = redis.call('TYPE', KEYS[23]).ok
            local truncated_generation = nil
            local truncation_fence_invalid = false
            if truncated then
              if truncated_generation_type == 'string' then
                truncated_generation = redis.call('GET', KEYS[23])
              else
                truncation_fence_invalid = true
              end
            elseif truncated_generation_type ~= 'none' then
              truncated_invalid = true
            end
            if stalled_invalid or production_complete_invalid or truncated_invalid then
              invalid_active_state = true
            end
            if truncation_fence_invalid or (truncated and not current_generation) then
              return {0, current_generation or '', -5, {}, {}}
            end

            local heartbeat_type = redis.call('TYPE', KEYS[5]).ok
            if heartbeat_type ~= 'none' and heartbeat_type ~= 'string' then
              invalid_active_state = true
            end

            local function retry_snapshot_digest(failed, errors)
              local pieces = {'failures', tostring(#failed)}
              for _, identifier in ipairs(failed) do
                pieces[#pieces + 1] = tostring(string.len(identifier))
                pieces[#pieces + 1] = identifier
              end
              pieces[#pieces + 1] = 'errors'
              pieces[#pieces + 1] = tostring(#errors)
              for _, identifier in ipairs(errors) do
                pieces[#pieces + 1] = tostring(string.len(identifier))
                pieces[#pieces + 1] = identifier
              end
              return redis.sha1hex(table.concat(pieces, string.char(0)))
            end

            local function read_safe_integer(key)
              if redis.call('TYPE', key).ok ~= 'string' then
                return nil
              end
              local validation = redis.pcall('INCRBY', key, 0)
              if type(validation) == 'table' and validation.err then
                return nil
              end
              local value = tonumber(validation)
              if not value or value < 0 or value > max_safe_integer then
                return nil
              end
              return value
            end

            local required_stats = {}
            for key_index = 7, 16 do
              required_stats[#required_stats + 1] = KEYS[key_index]
            end
            local existing_stat_count = redis.call('EXISTS', unpack(required_stats))
            local stat_values = {}
            if existing_stat_count == 10 then
              for key_index = 7, 16 do
                local value = read_safe_integer(KEYS[key_index])
                if value == nil then
                  invalid_active_state = true
                else
                  stat_values[#stat_values + 1] = value
                end
              end
              if not invalid_active_state then
                local runs = stat_values[1]
                local reported = stat_values[3] + stat_values[4] + stat_values[5] + stat_values[6]
                if stat_values[9] > stat_values[10] or runs < stat_values[7] + stat_values[8] or
                  runs - stat_values[7] - stat_values[8] ~= reported then
                  invalid_active_state = true
                end
              end
            elseif existing_stat_count > 0 or production_complete then
              invalid_active_state = true
            end
            if not retained_ttl and (stream_exists or current_generation or existing_stat_count > 0) then
              invalid_active_state = true
            end
            if existing_stat_count > 0 and not current_generation then
              invalid_active_state = true
            end

            -- Active pre-production attempts are safe to join only after all
            -- retained state passes validation. Terminal attempts fall through
            -- to grace handling and fenced retry takeover below.
            if stream_exists and current_generation and not stalled and not invalid_active_state then
              local terminal_complete = production_complete and existing_stat_count == 10 and
                stat_values[9] == stat_values[10]
              if truncated and truncated_generation ~= current_generation then
                if requested_ttl ~= retained_ttl then
                  return {0, current_generation, -4, {}, {}}
                end
                -- A mode-3 replacement generation is already active. Join it as
                -- an explicitly aborted follower instead of replacing its token.
                return {0, current_generation, -3, {}, {}}
              elseif not truncated and not terminal_complete then
                if requested_ttl ~= retained_ttl then
                  return {0, current_generation, -4, {}, {}}
                end
                return {0, current_generation, -1, {}, {}}
              end
            end

            local mode = 0 -- new run
            local previous_failures = {}
            local previous_errors = {}

            if stalled or invalid_active_state then
              mode = 2 -- fail-closed full rerun
            elseif existing_stat_count == 10 then
              local failures = stat_values[4]
              local errors = stat_values[5]
              local acks = stat_values[9]
              local size = stat_values[10]

              if truncated then
                mode = 3 -- intentionally aborted at max_failures
              elseif acks == size and production_complete then
                local retry_set_type = redis.call('TYPE', KEYS[6]).ok
                local skipped_list_type = redis.call('TYPE', KEYS[17]).ok
                local failed_list_type = redis.call('TYPE', KEYS[18]).ok
                local error_list_type = redis.call('TYPE', KEYS[19]).ok
                local digest_type = redis.call('TYPE', KEYS[22]).ok
                if (retry_set_type ~= 'none' and retry_set_type ~= 'set') or
                  (skipped_list_type ~= 'none' and skipped_list_type ~= 'list') or
                  (failed_list_type ~= 'none' and failed_list_type ~= 'list') or
                  (error_list_type ~= 'none' and error_list_type ~= 'list') or digest_type ~= 'string' then
                  mode = 2
                else
                  previous_failures = redis.call('LRANGE', KEYS[18], 0, -1)
                  previous_errors = redis.call('LRANGE', KEYS[19], 0, -1)
                  local expected_digest = redis.call('GET', KEYS[22])
                  local actual_digest = retry_snapshot_digest(previous_failures, previous_errors)
                  if #previous_failures ~= failures or #previous_errors ~= errors or expected_digest ~= actual_digest then
                    mode = 2
                  else
                    mode = 1 -- valid selective retry
                  end
                end
              else
                mode = 2
              end
            elseif existing_stat_count > 0 then
              mode = 2
            else
              -- Auxiliary state without statistics is an abandoned/corrupt run,
              -- not a genuinely new run ID. The generation token is excluded
              -- because it intentionally survives cleanup until the shared TTL.
              local auxiliary_count = redis.call(
                'EXISTS', KEYS[3], KEYS[4], KEYS[5], KEYS[6], KEYS[17], KEYS[18], KEYS[19], KEYS[20], KEYS[21], KEYS[22], KEYS[23], KEYS[24]
              )
              if auxiliary_count > 0 then
                mode = 2
              end
            end

            -- A completed attempt must remain fenced for the full grace period,
            -- whether or not its stream survived cleanup. Wait and re-register
            -- rather than joining a terminal generation with no retry work.
            if mode == 1 and current_generation then
              local completed_at = nil
              if redis.call('TYPE', KEYS[21]).ok == 'string' then
                completed_at = tonumber(redis.call('GET', KEYS[21]))
              end
              if not completed_at then
                mode = 2
              elseif ARGV[6] ~= current_generation then
                local redis_time = redis.call('TIME')
                local now = tonumber(redis_time[1]) + tonumber(redis_time[2]) / 1000000
                local grace = tonumber(ARGV[5])
                local remaining_grace = grace - (now - completed_at)
                if remaining_grace > grace then
                  remaining_grace = grace
                end
                if remaining_grace > 0 then
                  -- The terminal snapshot may have been written with a shorter
                  -- TTL than this retry invocation requests. Refresh every
                  -- validated retained key before sleeping so the snapshot
                  -- survives the full current grace period and safety margin.
                  redis.call('SET', KEYS[24], requested_ttl, 'EX', requested_ttl)
                  for key_index = 1, #KEYS do
                    if redis.call('EXISTS', KEYS[key_index]) == 1 then
                      redis.call('EXPIRE', KEYS[key_index], ARGV[2])
                    end
                  end
                  return {0, current_generation, -2, {}, {}, tostring(remaining_grace)}
                end
              end
            end

            -- No active attempt reaches here. A random token never repeats after
            -- expiry/eviction, so old workers cannot regain authority over a new
            -- attempt. All destructive changes and group creation are atomic.
            redis.call('DEL', KEYS[1])
            if mode == 2 then
              for key_index = 3, 23 do
                redis.call('DEL', KEYS[key_index])
              end
              previous_failures = {}
              previous_errors = {}
            else
              redis.call('DEL', KEYS[4], KEYS[5], KEYS[6], KEYS[21], KEYS[22])
              if mode == 1 or mode == 3 then
                redis.call('SET', KEYS[15], 0, 'EX', ARGV[2])
                redis.call('SET', KEYS[16], 0, 'EX', ARGV[2])
              else
                redis.call('DEL', KEYS[15], KEYS[16])
              end
              if mode == 3 then
                redis.call('SET', KEYS[20], 1, 'EX', ARGV[2])
              end
            end

            local generation = ARGV[4]
            redis.call('SET', KEYS[2], generation, 'EX', ARGV[2])
            redis.call('SET', KEYS[24], requested_ttl, 'EX', requested_ttl)
            local group_name = ARGV[1] .. '-' .. generation
            redis.call('XGROUP', 'CREATE', KEYS[1], group_name, '0', 'MKSTREAM')
            redis.call('SET', KEYS[5], 0, 'EX', ARGV[2])
            -- Retained state may come from an attempt with a shorter TTL. Align
            -- every surviving key with this generation before returning so a
            -- mode-3 follower cannot lose its truncation discriminator between
            -- registration and result adjustment.
            for key_index = 1, #KEYS do
              if redis.call('EXISTS', KEYS[key_index]) == 1 then
                redis.call('EXPIRE', KEYS[key_index], ARGV[2])
              end
            end
            return {1, generation, mode, previous_failures, previous_errors}
          LUA
        end

        sig { returns(String) }
        def reset_results_script
          @reset_results_script ||= redis.script(:load, <<~LUA)
            -- KEYS match adjust_results_script: generation, stream, retry_set,
            -- control markers, ten statistics, three result lists, completed_at,
            -- retry_snapshot_digest, truncated_generation, and retention_ttl.
            if redis.call('TYPE', KEYS[1]).ok ~= 'string' or redis.call('GET', KEYS[1]) ~= ARGV[1] then
              return redis.error_reply('STALEATTEMPT missing or mismatched generation')
            elseif redis.call('TYPE', KEYS[2]).ok ~= 'stream' then
              return redis.error_reply('COORDINATORSTREAM missing or invalid stream')
            end
            if redis.call('TYPE', KEYS[24]).ok ~= 'string' then
              return redis.error_reply('COORDINATORSTATE missing retention TTL')
            end
            local retention_validation = redis.pcall('INCRBY', KEYS[24], 0)
            local effective_ttl = tonumber(retention_validation)
            if (type(retention_validation) == 'table' and retention_validation.err) or
              not effective_ttl or tonumber(ARGV[2]) > effective_ttl then
              return redis.error_reply('COORDINATORCONFIG mismatched retention TTL')
            end

            local size = tonumber(ARGV[3])
            if not size or size < 0 or size % 1 ~= 0 or size > 9007199254740991 then
              return redis.error_reply('COORDINATORSTATE unsafe full-rerun size')
            end

            redis.call('DEL', KEYS[3], KEYS[4], KEYS[6], KEYS[7])
            for key_index = 8, 23 do
              redis.call('DEL', KEYS[key_index])
            end
            local reply = {}
            for stat_index = 1, 10 do
              local value = stat_index == 10 and size or 0
              redis.call('SET', KEYS[stat_index + 7], value, 'EX', effective_ttl)
              reply[stat_index] = value
            end
            redis.call('EXPIRE', KEYS[1], effective_ttl)
            redis.call('EXPIRE', KEYS[2], effective_ttl)
            redis.call('EXPIRE', KEYS[5], effective_ttl)
            redis.call('EXPIRE', KEYS[24], effective_ttl)
            return reply
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

            local function retry_snapshot_digest(failed_key, error_key)
              local failed = redis.call('LRANGE', failed_key, 0, -1)
              local errors = redis.call('LRANGE', error_key, 0, -1)
              local pieces = {'failures', tostring(#failed)}
              for _, identifier in ipairs(failed) do
                pieces[#pieces + 1] = tostring(string.len(identifier))
                pieces[#pieces + 1] = identifier
              end
              pieces[#pieces + 1] = 'errors'
              pieces[#pieces + 1] = tostring(#errors)
              for _, identifier in ipairs(errors) do
                pieces[#pieces + 1] = tostring(string.len(identifier))
                pieces[#pieces + 1] = identifier
              end
              return redis.sha1hex(table.concat(pieces, string.char(0)))
            end

            -- Every statistics key is created before any stream entries are
            -- published. Refuse to recreate missing state as zero: doing so can
            -- make an incomplete run look complete when both acks and size become
            -- 0. This preflight occurs before any write because Redis does not
            -- roll back earlier script writes when a later command errors.
            if redis.call('TYPE', KEYS[19]).ok ~= 'string' then
              return redis.error_reply('COORDINATORSTATE missing or invalid key ' .. KEYS[19])
            end
            local current_generation = redis.call('GET', KEYS[19])
            if not current_generation then
              return redis.error_reply('COORDINATORSTATE missing required key ' .. KEYS[19])
            elseif current_generation ~= expected_generation then
              return redis.error_reply('STALEATTEMPT expected generation ' .. expected_generation)
            end
            if redis.call('TYPE', KEYS[24]).ok ~= 'string' then
              return redis.error_reply('COORDINATORSTATE missing retention TTL')
            end
            local retention_validation = redis.pcall('INCRBY', KEYS[24], 0)
            local effective_ttl = tonumber(retention_validation)
            if (type(retention_validation) == 'table' and retention_validation.err) or
              not effective_ttl or tonumber(ARGV[2]) > effective_ttl then
              return redis.error_reply('COORDINATORCONFIG mismatched retention TTL')
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
            local production_type = redis.call('TYPE', KEYS[16]).ok
            local production_complete = false
            if production_type == 'string' then
              if redis.call('GET', KEYS[16]) ~= '1' then
                return redis.error_reply('COORDINATORSTATE invalid production marker')
              end
              production_complete = true
            elseif production_type ~= 'none' then
              return redis.error_reply('COORDINATORSTATE invalid production marker type')
            end
            local digest_type = redis.call('TYPE', KEYS[22]).ok
            if digest_type ~= 'none' and digest_type ~= 'string' then
              return redis.error_reply('COORDINATORSTATE invalid retry snapshot digest type')
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
              if value < 0 or value > max_safe_integer then
                return redis.error_reply('COORDINATORSTATE unsafe statistic value ' .. stat_key)
              end
              stat_values[stat_index] = value
            end
            local runs = stat_values[1]
            local reported = stat_values[3] + stat_values[4] + stat_values[5] + stat_values[6]
            if stat_values[9] > stat_values[10] or runs < stat_values[7] + stat_values[8] or
              runs - stat_values[7] - stat_values[8] ~= reported then
              return redis.error_reply('COORDINATORSTATE inconsistent aggregate statistics')
            end

            local truncated_type = redis.call('TYPE', KEYS[20]).ok
            local truncated_generation_type = redis.call('TYPE', KEYS[23]).ok
            local truncated = false
            if truncated_type == 'string' then
              if redis.call('GET', KEYS[20]) ~= '1' or truncated_generation_type ~= 'string' then
                return redis.error_reply('COORDINATORSTATE invalid truncated marker')
              end
              truncated = true
            elseif truncated_type ~= 'none' or truncated_generation_type ~= 'none' then
              return redis.error_reply('COORDINATORSTATE invalid truncated marker type')
            end
            if truncated then
              local truncated_reply = {}
              for result_index = 1, result_count do
                truncated_reply[result_index] = 0
              end
              for stat_index = 1, 10 do
                truncated_reply[result_count + stat_index] = stat_values[stat_index]
              end
              truncated_reply[result_count + 11] = production_complete and 1 or 0
              truncated_reply[result_count + 12] = 1
              for key_index = 1, #KEYS do
                redis.call('EXPIRE', KEYS[key_index], effective_ttl)
              end
              return truncated_reply
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
              if not allowed_result_types[result_type] or not assertions or assertions < 0 or assertions % 1 ~= 0 then
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
            if updated_acks == updated_size and production_complete then
              local redis_time = redis.call('TIME')
              local completed_at = tonumber(redis_time[1]) + tonumber(redis_time[2]) / 1000000
              redis.call('SET', KEYS[21], completed_at, 'EX', effective_ttl)
              local digest = retry_snapshot_digest(KEYS[14], KEYS[15])
              redis.call('SET', KEYS[22], digest, 'EX', effective_ttl)
            end
            reply[result_count + 11] = production_complete and 1 or 0
            reply[result_count + 12] = 0

            for key_index = 1, #KEYS do
              redis.call('EXPIRE', KEYS[key_index], effective_ttl)
            end

            return reply
          LUA
        end

        sig { returns(String) }
        def adjust_results_script
          @adjust_results_script ||= redis.script(:load, <<~LUA)
            if redis.call('TYPE', KEYS[1]).ok ~= 'string' then
              return redis.error_reply('COORDINATORSTATE missing or invalid key ' .. KEYS[1])
            end
            local current_generation = redis.call('GET', KEYS[1])
            if not current_generation then
              return redis.error_reply('COORDINATORSTATE missing required key ' .. KEYS[1])
            elseif current_generation ~= ARGV[1] then
              return redis.error_reply('STALEATTEMPT expected generation ' .. ARGV[1])
            end
            if redis.call('TYPE', KEYS[24]).ok ~= 'string' then
              return redis.error_reply('COORDINATORSTATE missing retention TTL')
            end
            local retention_validation = redis.pcall('INCRBY', KEYS[24], 0)
            local effective_ttl = tonumber(retention_validation)
            if (type(retention_validation) == 'table' and retention_validation.err) or
              not effective_ttl or tonumber(ARGV[2]) > effective_ttl then
              return redis.error_reply('COORDINATORCONFIG mismatched retention TTL')
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
            local digest_type = redis.call('TYPE', KEYS[22]).ok
            if digest_type ~= 'none' and digest_type ~= 'string' then
              return redis.error_reply('COORDINATORSTATE invalid retry snapshot digest type')
            end
            local truncated_type = redis.call('TYPE', KEYS[7]).ok
            local truncated_generation_type = redis.call('TYPE', KEYS[23]).ok
            if truncated_type == 'string' then
              if redis.call('GET', KEYS[7]) ~= '1' or truncated_generation_type ~= 'string' then
                return redis.error_reply('COORDINATORSTATE invalid truncated state')
              end
            elseif truncated_type ~= 'none' or truncated_generation_type ~= 'none' then
              return redis.error_reply('COORDINATORSTATE invalid truncated state type')
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
              local updated_value = delta and current_value + delta or nil
              if not delta or delta % 1 ~= 0 or updated_value < 0 or updated_value > max_safe_integer then
                return redis.error_reply('COORDINATORSTATE unsafe statistic value ' .. stat_key)
              end
            end

            if ARGV[3] == '1' then
              redis.call('DEL', KEYS[19], KEYS[20])
            end
            redis.call('DEL', KEYS[22])
            local reply = {}
            for stat_index = 1, 10 do
              reply[stat_index] = redis.call('INCRBY', KEYS[stat_index + 7], ARGV[stat_index + 4])
            end
            for key_index = 1, #KEYS do
              redis.call('EXPIRE', KEYS[key_index], effective_ttl)
            end
            return reply
          LUA
        end

        sig { returns(String) }
        def publish_tests_script
          @publish_tests_script ||= redis.script(:load, <<~LUA)
            if redis.call('TYPE', KEYS[1]).ok ~= 'string' then
              return redis.error_reply('COORDINATORSTATE missing or invalid key ' .. KEYS[1])
            end
            local current_generation = redis.call('GET', KEYS[1])
            if not current_generation then
              return redis.error_reply('COORDINATORSTATE missing required key ' .. KEYS[1])
            elseif current_generation ~= ARGV[1] then
              return redis.error_reply('STALEATTEMPT expected generation ' .. ARGV[1])
            elseif redis.call('TYPE', KEYS[2]).ok ~= 'stream' then
              return redis.error_reply('COORDINATORSTREAM missing or invalid key ' .. KEYS[2])
            end
            if redis.call('TYPE', KEYS[11]).ok ~= 'string' then
              return redis.error_reply('COORDINATORSTATE missing retention TTL')
            end
            local retention_validation = redis.pcall('INCRBY', KEYS[11], 0)
            local effective_ttl = tonumber(retention_validation)
            if (type(retention_validation) == 'table' and retention_validation.err) or
              not effective_ttl or tonumber(ARGV[2]) > effective_ttl then
              return redis.error_reply('COORDINATORCONFIG mismatched retention TTL')
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
            for list_index = 8, 9 do
              local list_type = redis.call('TYPE', KEYS[list_index]).ok
              if list_type ~= 'none' and list_type ~= 'list' then
                return redis.error_reply('COORDINATORSTATE invalid retry result list type')
              end
            end
            local digest_type = redis.call('TYPE', KEYS[10]).ok
            if digest_type ~= 'none' and digest_type ~= 'string' then
              return redis.error_reply('COORDINATORSTATE invalid retry snapshot digest type')
            end

            local function retry_snapshot_digest(failed_key, error_key)
              local failed = redis.call('LRANGE', failed_key, 0, -1)
              local errors = redis.call('LRANGE', error_key, 0, -1)
              local pieces = {'failures', tostring(#failed)}
              for _, identifier in ipairs(failed) do
                pieces[#pieces + 1] = tostring(string.len(identifier))
                pieces[#pieces + 1] = identifier
              end
              pieces[#pieces + 1] = 'errors'
              pieces[#pieces + 1] = tostring(#errors)
              for _, identifier in ipairs(errors) do
                pieces[#pieces + 1] = tostring(string.len(identifier))
                pieces[#pieces + 1] = identifier
              end
              return redis.sha1hex(table.concat(pieces, string.char(0)))
            end

            local max_safe_integer = 9007199254740991
            local function read_safe_counter(key)
              if redis.call('TYPE', key).ok ~= 'string' then
                return nil
              end
              local validation = redis.pcall('INCRBY', key, 0)
              if type(validation) == 'table' and validation.err then
                return nil
              end
              local value = tonumber(validation)
              if not value or value < 0 or value > max_safe_integer then
                return nil
              end
              return value
            end

            local acks = read_safe_counter(KEYS[5])
            local size = read_safe_counter(KEYS[6])
            if not acks or not size or acks > size then
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
              redis.call('SET', KEYS[3], 1, 'EX', effective_ttl)
              if acks == size then
                local redis_time = redis.call('TIME')
                local completed_at = tonumber(redis_time[1]) + tonumber(redis_time[2]) / 1000000
                redis.call('SET', KEYS[7], completed_at, 'EX', effective_ttl)
                local digest = retry_snapshot_digest(KEYS[8], KEYS[9])
                redis.call('SET', KEYS[10], digest, 'EX', effective_ttl)
              end
            end
            for key_index = 1, #KEYS do
              redis.call('EXPIRE', KEYS[key_index], effective_ttl)
            end
            return test_count
          LUA
        end

        sig { returns(String) }
        def heartbeat_script
          @heartbeat_script ||= redis.script(:load, <<~LUA)
            local generation_type = redis.call('TYPE', KEYS[1]).ok
            if generation_type == 'none' then
              return 0
            elseif generation_type ~= 'string' then
              return redis.error_reply('COORDINATORSTATE invalid key type ' .. KEYS[1])
            end
            local current_generation = redis.call('GET', KEYS[1])
            if not current_generation or current_generation ~= ARGV[1] then
              return 0
            end
            if redis.call('TYPE', KEYS[3]).ok ~= 'string' then
              return redis.error_reply('COORDINATORSTATE missing retention TTL')
            end
            local retention_validation = redis.pcall('INCRBY', KEYS[3], 0)
            local effective_ttl = tonumber(retention_validation)
            if (type(retention_validation) == 'table' and retention_validation.err) or
              not effective_ttl or tonumber(ARGV[2]) > effective_ttl then
              return redis.error_reply('COORDINATORCONFIG mismatched retention TTL')
            end
            local heartbeat_type = redis.call('TYPE', KEYS[2]).ok
            if heartbeat_type ~= 'none' and heartbeat_type ~= 'string' then
              return redis.error_reply('COORDINATORSTATE invalid key type ' .. KEYS[2])
            end
            redis.call('INCR', KEYS[2])
            redis.call('EXPIRE', KEYS[1], effective_ttl)
            redis.call('EXPIRE', KEYS[2], effective_ttl)
            redis.call('EXPIRE', KEYS[3], effective_ttl)
            return 1
          LUA
        end

        sig { returns(String) }
        def mark_attempt_state_script
          @mark_attempt_state_script ||= redis.script(:load, <<~LUA)
            if redis.call('TYPE', KEYS[1]).ok ~= 'string' then
              return 0
            end
            local current_generation = redis.call('GET', KEYS[1])
            if not current_generation or current_generation ~= ARGV[1] then
              return 0
            end
            if redis.call('TYPE', KEYS[7]).ok ~= 'string' then
              return redis.error_reply('COORDINATORSTATE missing retention TTL')
            end
            local retention_validation = redis.pcall('INCRBY', KEYS[7], 0)
            local effective_ttl = tonumber(retention_validation)
            if (type(retention_validation) == 'table' and retention_validation.err) or
              not effective_ttl or tonumber(ARGV[2]) > effective_ttl then
              return redis.error_reply('COORDINATORCONFIG mismatched retention TTL')
            end

            local production_type = redis.call('TYPE', KEYS[3]).ok
            if production_type == 'string' then
              if redis.call('GET', KEYS[3]) ~= '1' then
                return redis.error_reply('COORDINATORSTATE invalid production marker')
              end
              local function read_safe_counter(key)
                if redis.call('TYPE', key).ok ~= 'string' then
                  return nil
                end
                local validation = redis.pcall('INCRBY', key, 0)
                if type(validation) == 'table' and validation.err then
                  return nil
                end
                local value = tonumber(validation)
                if not value or value < 0 or value > 9007199254740991 then
                  return nil
                end
                return value
              end
              local acks = read_safe_counter(KEYS[4])
              local size = read_safe_counter(KEYS[5])
              if not acks or not size or acks > size then
                return redis.error_reply('COORDINATORSTATE invalid completion counters')
              elseif acks == size then
                return 2
              end
            elseif production_type ~= 'none' then
              return redis.error_reply('COORDINATORSTATE invalid production marker type')
            end

            redis.call('SET', KEYS[2], 1, 'EX', effective_ttl)
            redis.call('SET', KEYS[6], current_generation, 'EX', effective_ttl)
            redis.call('EXPIRE', KEYS[1], effective_ttl)
            redis.call('EXPIRE', KEYS[7], effective_ttl)
            return 1
          LUA
        end

        sig { returns(String) }
        def cleanup_script
          @cleanup_script ||= redis.script(:load, <<~LUA)
            if redis.call('TYPE', KEYS[2]).ok ~= 'string' then
              return 0
            end
            local current_generation = redis.call('GET', KEYS[2])
            if not current_generation or current_generation ~= ARGV[1] then
              return 0
            end
            if redis.call('TYPE', KEYS[3]).ok ~= 'string' then
              return 0
            end
            local retention_validation = redis.pcall('INCRBY', KEYS[3], 0)
            local effective_ttl = tonumber(retention_validation)
            if (type(retention_validation) == 'table' and retention_validation.err) or
              not effective_ttl or tonumber(ARGV[3]) > effective_ttl then
              return 0
            end

            redis.call('EXPIRE', KEYS[2], effective_ttl)
            redis.call('EXPIRE', KEYS[3], effective_ttl)
            redis.pcall('XGROUP', 'DESTROY', KEYS[1], ARGV[2])
            redis.call('DEL', KEYS[1])
            return 1
          LUA
        end

        sig { returns(String) }
        def abort_script
          @abort_script ||= redis.script(:load, <<~LUA)
            if redis.call('TYPE', KEYS[2]).ok ~= 'string' then
              return 0
            end
            local current_generation = redis.call('GET', KEYS[2])
            if not current_generation or current_generation ~= ARGV[1] then
              return 0
            end

            if redis.call('TYPE', KEYS[4]).ok ~= 'string' then
              return 0
            end
            local retention_validation = redis.pcall('INCRBY', KEYS[4], 0)
            local effective_ttl = tonumber(retention_validation)
            if (type(retention_validation) == 'table' and retention_validation.err) or
              not effective_ttl or tonumber(ARGV[3]) > effective_ttl then
              return 0
            end

            redis.call('EXPIRE', KEYS[2], effective_ttl)
            redis.call('EXPIRE', KEYS[4], effective_ttl)
            redis.call('SET', KEYS[3], 1, 'EX', effective_ttl)
            redis.pcall('XGROUP', 'DESTROY', KEYS[1], ARGV[2])
            redis.call('DEL', KEYS[1])
            return 1
          LUA
        end

        sig { params(script_name: Symbol).returns(String) }
        def resolve_script(script_name)
          case script_name
          when :register_consumergroup then register_consumergroup_script
          when :read_results then read_results_script
          when :reset_results then reset_results_script
          when :commit_results then commit_results_script
          when :cleanup then cleanup_script
          when :abort then abort_script
          when :adjust_results then adjust_results_script
          when :publish_tests then publish_tests_script
          when :heartbeat then heartbeat_script
          when :mark_attempt_state then mark_attempt_state_script
          else raise ArgumentError, "Unknown Redis script: #{script_name}"
          end
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
            if script_name == :read_results
              redis.evalsha(resolve_script(script_name), keys: keys, argv: argv)
            else
              # Script loading and EVALSHA share one serialized no-reconnect
              # scope. redis-rb toggles reconnect state outside its command
              # monitor, so resolving the SHA before taking this mutex could let
              # the heartbeat invalidate a producer's pending SCRIPT LOAD.
              @mutating_script_mutex.synchronize do
                script_sha = resolve_script(script_name)
                redis.without_reconnect do
                  redis.evalsha(script_sha, keys: keys, argv: argv)
                end
              end
            end
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
          when :read_results then @read_results_script = nil
          when :reset_results then @reset_results_script = nil
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
                list_key(ResultType::Failed.serialize),
                list_key(ResultType::Error.serialize),
                key("retry_snapshot_digest"),
                key("retention_ttl"),
              ],
              argv: argv,
            )
          end
        end

        sig { void }
        def mark_run_truncated
          generation = T.must(@attempt_generation)
          applied = execute_script(
            script_name: :mark_attempt_state,
            keys: [
              key("attempt_generation"),
              key("truncated"),
              key("production_complete"),
              key("acks"),
              key("size"),
              key("truncated_generation"),
              key("retention_ttl"),
            ],
            argv: [generation, configuration.key_ttl_seconds],
          )
          return if [1, 2].include?(applied) || attempt_superseded?

          abort_with_diagnostic(<<~DIAGNOSTIC)
            ERROR: minitest-distributed could not persist max-failures truncation state.
            run_id=#{configuration.run_id} worker_id=#{configuration.worker_id}
            The attempt generation key may have expired, been evicted, or been deleted.
          DIAGNOSTIC
        end

        sig { returns(Thread) }
        def start_production_heartbeat
          generation = T.must(@attempt_generation)
          interval = [configuration.stall_timeout_seconds / 2, MAX_PRODUCTION_HEARTBEAT_INTERVAL_SECONDS].min
          control = HeartbeatControl.new
          @production_heartbeat_control = control
          @production_heartbeat_error = nil
          Thread.new do
            Thread.current.report_on_exception = false
            loop do
              stop_requested = control.mutex.synchronize do
                control.condition.wait(control.mutex, interval) unless control.stop_requested
                control.stop_requested
              end
              break if stop_requested

              begin
                updated = execute_script(
                  script_name: :heartbeat,
                  keys: [key("attempt_generation"), key("production_heartbeat"), key("retention_ttl")],
                  argv: [generation, configuration.key_ttl_seconds],
                )
                break unless updated == 1
              rescue Redis::BaseConnectionError
                # Redis clients reconnect on the next command. Keep this watchdog
                # alive so a transient connection failure does not silently stop
                # heartbeats during slow test discovery.
                next
              rescue StandardError => error
                @production_heartbeat_error = error
                break
              end
            end
          end
        end

        sig { params(thread: Thread, propagate_error: T::Boolean).void }
        def stop_production_heartbeat(thread, propagate_error:)
          if (control = @production_heartbeat_control)
            control.mutex.synchronize do
              control.stop_requested = true
              control.condition.broadcast
            end
          end
          thread.join
          @production_heartbeat_control = nil
          heartbeat_error = @production_heartbeat_error
          raise heartbeat_error if heartbeat_error && propagate_error
        end

        sig { params(results: ResultAggregate).returns(T::Boolean) }
        def run_complete?(results)
          results.equal?(@combined_results) && results.complete? && @combined_results_production_complete == true
        end

        sig { returns(T.nilable(Integer)) }
        def current_production_heartbeat
          raw_heartbeat = read_control_string("production_heartbeat")
          return unless raw_heartbeat

          heartbeat = parse_redis_integer(raw_heartbeat)
          raise CoordinatorStateError, "production_heartbeat=#{raw_heartbeat.inspect}" unless heartbeat

          heartbeat
        end

        # Read all the state needed to distinguish a legitimately slow pending
        # test from a drained queue whose completion counters can no longer agree.
        # This deliberately bypasses `@combined_results`, which is memoized.
        sig { returns(StallProbe) }
        def probe_stall
          counters, pending_summary, groups, stream_info, production_complete_type, heartbeat_type,
            generation_type = redis.pipelined do |pipeline|
              pipeline.mget(key("acks"), key("size"), key("production_complete"), key("production_heartbeat"))
              pipeline.xpending(stream_key, group_name)
              pipeline.xinfo("groups", stream_key)
              pipeline.xinfo("stream", stream_key)
              pipeline.call("TYPE", key("production_complete"))
              pipeline.call("TYPE", key("production_heartbeat"))
              pipeline.call("TYPE", key("attempt_generation"))
            end

          raw_acks, raw_size, raw_production_complete, raw_production_heartbeat = T.unsafe(counters)
          group = T.unsafe(groups).find { |candidate| candidate.fetch("name") == group_name }
          raw_lag = group&.fetch("lag", nil)
          invalid_values = T.let([], T::Array[String])
          acks = parse_redis_integer(raw_acks)
          size = parse_redis_integer(raw_size)
          lag = parse_redis_integer(raw_lag)
          production_heartbeat = parse_redis_integer(raw_production_heartbeat)
          unless ["none", "string"].include?(production_complete_type)
            invalid_values << "production_complete_type=#{production_complete_type}"
          end
          unless ["none", "string"].include?(heartbeat_type)
            invalid_values << "production_heartbeat_type=#{heartbeat_type}"
          end
          invalid_values << "attempt_generation_type=#{generation_type}" unless generation_type == "string"
          if !raw_production_complete.nil? && raw_production_complete != "1"
            invalid_values << "production_complete=#{raw_production_complete.inspect}"
          end
          invalid_values << "acks=#{raw_acks.inspect}" if !raw_acks.nil? && acks.nil?
          invalid_values << "size=#{raw_size.inspect}" if !raw_size.nil? && size.nil?
          invalid_values << "lag=#{raw_lag.inspect}" if !raw_lag.nil? && lag.nil?
          if !raw_production_heartbeat.nil? && production_heartbeat.nil?
            invalid_values << "production_heartbeat=#{raw_production_heartbeat.inspect}"
          end

          # Redis added the explicit group lag field in version 7. On older
          # versions, equal delivery and stream IDs still prove that there are no
          # undelivered entries because this coordinator never trims the stream.
          if lag.nil? && group && group.fetch("last-delivered-id") == T.unsafe(stream_info).fetch("last-generated-id")
            lag = 0
          end

          raw_pending_count = T.unsafe(pending_summary).fetch("size")
          pending_count = parse_redis_integer(raw_pending_count)
          invalid_values << "pending=#{raw_pending_count.inspect}" if pending_count.nil?

          StallProbe.new(
            acks: acks,
            size: size,
            pending_count: pending_count || 0,
            lag: lag,
            production_complete: raw_production_complete == "1",
            production_heartbeat: production_heartbeat,
            invalid_values: invalid_values,
          )
        end

        sig { params(probe: StallProbe).void }
        def abort_stalled_run(probe)
          abort_with_diagnostic(format_stall_diagnostic(probe))
        end

        sig { params(error: Redis::CommandError).void }
        def handle_coordinator_state_error(error)
          if attempt_truncated?
            @attempt_truncated = true
            @aborted = true
            emit_message(<<~DIAGNOSTIC)
              ERROR: minitest-distributed stopped this worker after another worker truncated the run.
              run_id=#{configuration.run_id} worker_id=#{configuration.worker_id}
              redis_error=#{error.message.inspect}
              The run was intentionally cut short at max_failures before this local batch could be committed.
            DIAGNOSTIC
            return
          end
          return if attempt_superseded?

          @combined_results = nil
          begin
            results = combined_results
          rescue CoordinatorStateError => parse_error
            abort_with_diagnostic(<<~DIAGNOSTIC)
              ERROR: minitest-distributed could not parse Redis coordinator statistics.
              run_id=#{configuration.run_id} worker_id=#{configuration.worker_id}
              redis_error=#{error.message.inspect} parse_error=#{parse_error.message.inspect}
            DIAGNOSTIC
            return
          rescue Redis::CommandError => state_error
            abort_with_diagnostic(<<~DIAGNOSTIC)
              ERROR: minitest-distributed lost required Redis coordinator state and aborted the run.
              run_id=#{configuration.run_id} worker_id=#{configuration.worker_id}
              redis_error=#{error.message.inspect} state_error=#{state_error.message.inspect}
              The retained coordinator statistics are missing, invalid, or inconsistent.
              The run is incomplete, so this was not normal cleanup.
            DIAGNOSTIC
            return
          end
          mandatory_state_missing = error.message.start_with?("COORDINATORSTATE", "WRONGTYPE")
          return if !mandatory_state_missing && run_complete?(results)

          state = "run_id=#{configuration.run_id} worker_id=#{configuration.worker_id} " \
            "acks=#{results.acks} size=#{results.size} redis_error=#{error.message.inspect}"
          diagnostic = <<~DIAGNOSTIC
            ERROR: minitest-distributed lost required Redis coordinator state and aborted the run.
            #{state}
            The run is incomplete, so this was not normal cleanup. A run key may have expired, been evicted, or been deleted.
          DIAGNOSTIC
          abort_with_diagnostic(diagnostic)
        rescue CoordinatorStateError => parse_error
          abort_with_diagnostic(<<~DIAGNOSTIC)
            ERROR: minitest-distributed could not parse Redis coordinator state.
            run_id=#{configuration.run_id} worker_id=#{configuration.worker_id}
            redis_error=#{error.message.inspect} parse_error=#{parse_error.message.inspect}
          DIAGNOSTIC
        end

        sig { returns(T::Boolean) }
        def attempt_superseded?
          attempt_generation = @attempt_generation
          return false unless attempt_generation

          generation_key = key("attempt_generation")
          return false unless redis.type(generation_key) == "string"

          current_generation = redis.get(generation_key)
          return false if current_generation.nil?

          current_generation != attempt_generation
        end

        sig { params(name: String).returns(T.nilable(String)) }
        def read_control_string(name)
          control_key = key(name)
          key_type = redis.type(control_key)
          return if key_type == "none"
          raise CoordinatorStateError, "#{name} has Redis type #{key_type}" unless key_type == "string"

          redis.get(control_key)
        end

        sig { returns(T::Boolean) }
        def commit_observed_truncation?
          @attempt_truncated
        end

        sig { returns(T::Boolean) }
        def attempt_truncated?
          attempt_generation = @attempt_generation
          return false unless attempt_generation

          truncated_key = key("truncated")
          truncated_generation_key = key("truncated_generation")
          return false unless redis.type(truncated_key) == "string"
          return false unless redis.type(truncated_generation_key) == "string"

          redis.get(truncated_key) == "1" && redis.get(truncated_generation_key) == attempt_generation
        end

        sig { params(diagnostic: String).void }
        def abort_locally_with_diagnostic(diagnostic)
          @aborted = true
          @stall_diagnostic = diagnostic
          emit_message(diagnostic)
        end

        sig { params(diagnostic: String).void }
        def abort_with_diagnostic(diagnostic)
          generation = T.must(@attempt_generation)
          applied = execute_script(
            script_name: :abort,
            keys: [stream_key, key("attempt_generation"), key("stalled"), key("retention_ttl")],
            argv: [generation, group_name, configuration.key_ttl_seconds],
          )
          return if applied != 1 && attempt_superseded?

          # If ownership evidence itself was evicted, do not mutate shared state,
          # but still fail this worker with the diagnostic rather than silently
          # continuing or reporting success.
          abort_locally_with_diagnostic(diagnostic)
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

        sig { params(value: T.untyped).returns(T.nilable(Integer)) }
        def parse_redis_integer(value)
          integer = case value
          when Integer then value
          when String then value.match?(/\A-?\d+\z/) ? value.to_i : nil
          end
          return unless integer

          integer if integer.between?(0, MAX_SAFE_STATISTIC)
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
            keys: [stream_key, key("attempt_generation"), key("retention_ttl")],
            argv: [generation, group_name, configuration.key_ttl_seconds],
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

        sig { params(identifiers: T::Array[String]).returns(T.nilable(T::Array[Minitest::Runnable])) }
        def materialize_retry_tests(identifiers)
          identifiers.map do |identifier|
            runnable = DefinedRunnable.from_identifier(identifier)
            raise NameError, "retained test method no longer exists: #{identifier}" unless runnable.respond_to?(runnable.name)

            runnable
          end
        rescue StandardError
          nil
        end

        sig { params(size: Integer).void }
        def reset_combined_results_for_full_rerun(size:)
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
          keys.push(
            key("completed_at"),
            key("retry_snapshot_digest"),
            key("truncated_generation"),
            key("retention_ttl"),
          )
          updated = execute_script(
            script_name: :reset_results,
            keys: keys,
            argv: [generation, configuration.key_ttl_seconds, size],
          )
          update_combined_results(T.cast(updated, T::Array[Integer]), production_complete: false)
        end

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
          keys.push(
            key("completed_at"),
            key("retry_snapshot_digest"),
            key("truncated_generation"),
            key("retention_ttl"),
          )
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
          update_combined_results(T.cast(updated, T::Array[Integer]), production_complete: false)
        end

        sig { params(name: String).returns(String) }
        def key(name)
          "#{REDIS_PROTOCOL_NAMESPACE}/#{configuration.run_id}/#{name}"
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
            key("retry_snapshot_digest"),
            key("truncated_generation"),
            key("retention_ttl"),
          )

          response = T.unsafe(execute_script(script_name: :commit_results, keys: keys, argv: arguments))
          commit_statuses = T.cast(response.take(results.size), T::Array[Integer])
          aggregate_response = T.cast(response.drop(results.size), T::Array[Integer])
          attempt_truncated = aggregate_response.pop == 1
          production_complete = aggregate_response.pop == 1
          if attempt_truncated
            @attempt_truncated = true
            @aborted = true
          end
          update_combined_results(aggregate_response, production_complete: production_complete)
          build_runnable_results(results, commit_statuses)
        rescue Redis::CommandError => error
          if error.message.start_with?("STALEATTEMPT")
            # The Lua script already proved supersession atomically. Do not
            # re-read generation or truncation keys here: they may be evicted
            # before Ruby handles the response, but the executed batch must
            # still be recorded locally as discarded.
            return build_runnable_results(results, Array.new(results.size, 0))
          end

          cleanup_race_error = error.message.start_with?("NOGROUP", "COORDINATORCONFIG", "COORDINATORSTREAM") ||
            error.message.include?("no such key")
          raise unless cleanup_race_error

          # Another worker may have completed and cleaned up while this batch was
          # running. Preserve the reporter contract by presenting these local
          # results as uncommitted/discarded, but only when fresh counters prove
          # the shared run is already terminal. Incomplete state is handled by
          # consume's fail-closed coordinator-state path.
          @combined_results = nil
          terminal_results = combined_results
          raise unless run_complete?(terminal_results)

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

        sig { params(updated: T::Array[Integer], production_complete: T::Boolean).void }
        def update_combined_results(updated, production_complete:)
          @combined_results_production_complete = production_complete
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

        REDIS_PROTOCOL_NAMESPACE = "minitest/v3"
        private_constant :REDIS_PROTOCOL_NAMESPACE

        BASE_GROUP_NAME = "minitest-distributed-v3"
        private_constant :BASE_GROUP_NAME

        # Confirm a drained mismatch because the diagnostic probe itself uses
        # multiple pipelined Redis commands and is not an atomic snapshot.
        STALL_CONFIRMATION_SECONDS = 30.0
        private_constant :STALL_CONFIRMATION_SECONDS

        MAX_PRODUCTION_HEARTBEAT_INTERVAL_SECONDS = 30.0
        private_constant :MAX_PRODUCTION_HEARTBEAT_INTERVAL_SECONDS

        MAX_SAFE_STATISTIC = 9_007_199_254_740_991
        private_constant :MAX_SAFE_STATISTIC

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
