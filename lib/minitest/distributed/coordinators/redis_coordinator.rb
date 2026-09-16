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
          @stream_key = T.let(key("queue"), String)
          @group_name = T.let("minitest-distributed", String)
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
          # Whoever ends up creating the consumer group will act as leader,
          # and publish the list of tests to the stream.
          consumer_group_exists = false
          initial_attempt = begin
            # When using `redis.multi`, the second DEL command gets executed even if the initial GROUP
            # fails. This is bad, because only the leader should be issuing the DEL command.
            # When using EVAL and a Lua script, the script aborts after the first XGROUP command
            # fails, and the DEL never gets executed for followers.
            keys_deleted = redis.evalsha(
              register_consumergroup_script,
              keys: [stream_key, key("size"), key("acks"), key("production_complete")],
              argv: [group_name, configuration.key_ttl_seconds],
            )
            keys_deleted == 0
          rescue Redis::CommandError => ce
            if ce.message.include?("BUSYGROUP")
              # If Redis returns a BUSYGROUP error, it means that the consumer group already
              # exists. In our case, it means that another worker managed to successfully
              # run the XGROUP command, and will act as leader and publish the tests.
              # This worker can simply move on the consumer mode.
              consumer_group_exists = true
            else
              raise
            end
          end

          return if consumer_group_exists

          tests = T.let(
            if redis.exists?(key("stalled"))
              # A previous attempt lost coordinator state, so its failure lists and
              # statistics cannot be trusted as the basis for a selective retry.
              @aborted = true
              adjust_combined_results(ResultAggregate.new(size: 0))
              []
            elsif initial_attempt
              # If this is the first attempt for this run ID, we will schedule the full
              # test suite as returned by the test selector to run.

              tests_from_selector = test_selector.tests
              adjust_combined_results(ResultAggregate.new(size: tests_from_selector.size))
              tests_from_selector

            elsif configuration.retry_failures
              # Before starting a retry attempt, we first check if the previous attempt
              # was aborted before it was completed. If this is the case, we cannot use
              # retry mode, and should immediately fail the attempt.
              if combined_results.abort?
                # We mark this run as aborted, which causes this worker to not be successful.
                @aborted = true

                # We still publish an empty size run to Redis, so if there are any followers,
                # they will wind down normally. Only the leader will exit
                # with a non-zero exit status and fail the build; any follower will
                # exit with status 0.
                adjust_combined_results(ResultAggregate.new(size: 0))
                []
              else
                previous_failures, previous_errors, _deleted = redis.multi do |pipeline|
                  pipeline.lrange(list_key(ResultType::Failed.serialize), 0, -1)
                  pipeline.lrange(list_key(ResultType::Error.serialize), 0, -1)
                  pipeline.del(list_key(ResultType::Failed.serialize), list_key(ResultType::Error.serialize))
                end

                # We set the `size` key to the number of tests we are planning to schedule.
                # We also adjust the number of failures and errors back to 0.
                # We set the number of requeues to the number of tests that failed, so the
                # run statistics will reflect that we retried some failed test.
                #
                # However, normally requeues are not acked, as we expect the test to be acked
                # by another worker later. This makes the test loop think iot is already done.
                # To prevent this, we initialize the number of acks negatively, so it evens out
                # in the statistics.
                total_failures = previous_failures.length + previous_errors.length
                adjust_combined_results(ResultAggregate.new(
                  size: total_failures,
                  failures: -previous_failures.length,
                  errors: -previous_errors.length,
                  requeues: total_failures,
                ))

                # For subsequent attempts, we check the list of previous failures and
                # errors, and only schedule to re-run those tests. This allows for faster
                # retries of potentially flaky tests.
                test_identifiers_to_retry = T.let(previous_failures + previous_errors, T::Array[String])
                test_identifiers_to_retry.map { |identifier| DefinedRunnable.from_identifier(identifier) }
              end
            else
              adjust_combined_results(ResultAggregate.new(size: 0))
              []
            end,
            T::Array[Minitest::Runnable],
          )

          redis.pipelined do |pipeline|
            tests.each do |test|
              pipeline.xadd(stream_key, { class_name: T.must(test.class.name), method_name: test.name })
            end
            pipeline.set(key("production_complete"), "1", ex: configuration.key_ttl_seconds)
          end
        end

        sig { override.params(reporter: AbstractReporter).void }
        def consume(reporter:)
          exponential_backoff = INITIAL_BACKOFF
          last_progress_at = monotonic_time
          initial_results = combined_results
          observed_acks = T.let(initial_results.acks, T.nilable(Integer))
          observed_size = T.let(initial_results.size, T.nilable(Integer))
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
            # will start to fail - see the rescue block below.
            break if run_results.complete?

            # We also abort a run if we reach the maximum number of failures.
            break if run_results.abort?

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
                if !probe.acks.nil? && probe.acks == probe.size
                  break
                end

                counters_changed = probe.acks != observed_acks || probe.size != observed_size
                if counters_changed
                  observed_acks = probe.acks
                  observed_size = probe.size
                end

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
                  if incomplete_production_detected_at && !counters_changed
                    abort_stalled_run(probe)
                    break
                  else
                    # The leader may still be selecting tests. Give production a
                    # second full stall interval, but do not wait forever if the
                    # leader died or this marker was itself evicted.
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
          if ce.message.start_with?("NOGROUP") || ce.message.include?("no such key")
            # A normal cleanup and an evicted/deleted stream produce the same Redis
            # errors. Fresh counters distinguish a terminal run from data loss.
            handle_missing_stream_error(ce)
          else
            raise
          end
        end

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
          @register_consumergroup_script ||= T.let(redis.script(:load, <<~LUA), T.nilable(String))
            -- Try to create the consumergroup. This will raise an error if the
            -- consumergroup has already been registered by somebody else, which
            -- means another worker will be acting as leader.
            -- In that case, the next Redis DEL call will not be executed.
            redis.call('XGROUP', 'CREATE', KEYS[1], ARGV[1], '0', 'MKSTREAM')
            redis.call('EXPIRE', KEYS[1], ARGV[2])

            -- The leader should reset the size, acks and production marker for this
            -- run attempt. Only size and acks determine whether this is a retry.
            local attempt_keys_deleted = redis.call('DEL', KEYS[2], KEYS[3])
            redis.call('DEL', KEYS[4])
            return attempt_keys_deleted
          LUA
        end

        sig { returns(String) }
        def commit_results_script
          @commit_results_script ||= T.let(redis.script(:load, <<~LUA), T.nilable(String))
            local result_count = tonumber(ARGV[3])
            local argument_index = 4
            local commit_results = {}
            -- runs, assertions, passes, failures, errors, skips, requeues,
            -- discards, acks, size
            local deltas = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0}

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

            for key_index = 1, #KEYS do
              redis.call('EXPIRE', KEYS[key_index], ARGV[2])
            end

            return reply
          LUA
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
          EnqueuedRunnable.from_redis_stream_claim(result.fetch(stream_key, []), configuration: configuration)
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

        # Read all the state needed to distinguish a legitimately slow pending
        # test from a drained queue whose completion counters can no longer agree.
        # This deliberately bypasses `@combined_results`, which is memoized.
        sig { returns(StallProbe) }
        def probe_stall
          counters, pending_summary, groups, stream_info = redis.pipelined do |pipeline|
            pipeline.mget(key("acks"), key("size"), key("production_complete"))
            pipeline.xpending(stream_key, group_name)
            pipeline.xinfo("groups", stream_key)
            pipeline.xinfo("stream", stream_key)
          end

          raw_acks, raw_size, raw_production_complete = T.unsafe(counters)
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
          )
        end

        sig { params(probe: StallProbe).void }
        def abort_stalled_run(probe)
          abort_with_diagnostic(format_stall_diagnostic(probe))
        end

        sig { params(error: Redis::CommandError).void }
        def handle_missing_stream_error(error)
          @combined_results = nil
          results = combined_results
          return if results.complete? || results.abort?

          state = "run_id=#{configuration.run_id} worker_id=#{configuration.worker_id} " \
            "acks=#{results.acks} size=#{results.size} redis_error=#{error.message.inspect}"
          diagnostic = <<~DIAGNOSTIC
            ERROR: minitest-distributed lost its Redis stream or consumer group and aborted the run.
            #{state}
            The run is incomplete, so this was not normal cleanup. The stream may have been evicted or deleted.
          DIAGNOSTIC
          abort_with_diagnostic(diagnostic)
        end

        sig { params(diagnostic: String).void }
        def abort_with_diagnostic(diagnostic)
          redis.set(key("stalled"), "1", ex: configuration.key_ttl_seconds)
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
            "production_complete=#{probe.production_complete}"
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
          redis.xgroup(:destroy, stream_key, group_name)
          redis.del(stream_key)
        rescue Redis::CommandError
          # Apparently another consumer already removed the consumer group,
          # so we can assume that all the Redis cleanup was completed.
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

        # Refreshes the expiry of every key this run owns. Issued on the caller's
        # pipeline, so it costs no extra round trip. `EXPIRE` on a key that does not
        # exist is a no-op, so keys the run never writes are fine.
        sig { params(pipeline: T.untyped).void }
        def refresh_key_ttls(pipeline)
          ttl = configuration.key_ttl_seconds
          pipeline.expire(stream_key, ttl)
          pipeline.expire(key("retry_set"), ttl)
          pipeline.expire(key("production_complete"), ttl)
          pipeline.expire(key("stalled"), ttl)
          STATS_KEY_NAMES.each { |name| pipeline.expire(key(name), ttl) }
          LIST_KEY_RESULT_TYPES.each { |result_type| pipeline.expire(list_key(result_type.serialize), ttl) }
        end

        sig { params(results: ResultAggregate).void }
        def adjust_combined_results(results)
          updated = redis.multi do |pipeline|
            pipeline.incrby(key("runs"), results.runs)
            pipeline.incrby(key("assertions"), results.assertions)
            pipeline.incrby(key("passes"), results.passes)
            pipeline.incrby(key("failures"), results.failures)
            pipeline.incrby(key("errors"), results.errors)
            pipeline.incrby(key("skips"), results.skips)
            pipeline.incrby(key("requeues"), results.requeues)
            pipeline.incrby(key("discards"), results.discards)
            pipeline.incrby(key("acks"), results.acks)
            pipeline.incrby(key("size"), results.size)

            # Keep the run's keys on a sliding expiry. This runs after the INCRBYs so
            # the positional results below are unaffected. Test-result commits refresh
            # the same keys in `commit_results_script`, so they stay alive for the
            # duration of both production and consumption.
            refresh_key_ttls(pipeline)
          end

          update_combined_results(T.cast(updated.take(10), T::Array[Integer]))
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
            [group_name, configuration.key_ttl_seconds, results.size],
            T::Array[T.untyped],
          )
          results.each do |enqueued_runnable, result|
            arguments.concat([
              enqueued_runnable.entry_id,
              ResultType.of(result).serialize,
              enqueued_runnable.attempt_id,
              enqueued_runnable.identifier,
              result.assertions,
            ])
          end

          keys = [stream_key, key("retry_set")]
          keys.concat(STATS_KEY_NAMES.map { |name| key(name) })
          keys.concat(LIST_KEY_RESULT_TYPES.map { |result_type| list_key(result_type.serialize) })
          keys.concat([key("production_complete"), key("stalled")])

          response = T.unsafe(redis.evalsha(commit_results_script, keys: keys, argv: arguments))
          commit_statuses = response.take(results.size)
          update_combined_results(T.cast(response.drop(results.size), T::Array[Integer]))

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

        # Confirm a drained mismatch because the diagnostic probe itself uses
        # multiple pipelined Redis commands and is not an atomic snapshot.
        STALL_CONFIRMATION_SECONDS = 30.0
        private_constant :STALL_CONFIRMATION_SECONDS

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
