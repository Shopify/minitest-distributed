# typed: strict
# frozen_string_literal: true

require "redis"
require "set"

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
        end

        sig { override.params(reporter: Minitest::CompositeReporter, options: T::Hash[Symbol, T.untyped]).void }
        def register_reporters(reporter:, options:)
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
              keys: [stream_key, key("size"), key("acks")],
              argv: [group_name],
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

          tests = T.let([], T::Array[Minitest::Runnable])
          tests = if initial_attempt
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
              T.let([], T::Array[Minitest::Runnable])
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
            T.let([], T::Array[Minitest::Runnable])
          end

          redis.pipelined do |pipeline|
            tests.each do |test|
              pipeline.xadd(stream_key, { class_name: T.must(test.class.name), method_name: test.name })
            end
          end
        end

        sig { override.params(reporter: AbstractReporter).void }
        def consume(reporter:)
          exponential_backoff = INITIAL_BACKOFF
          loop do
            # First, see if there are any pending tests from other workers to claim.
            stale_runnables = claim_stale_runnables
            process_batch(stale_runnables, reporter)

            # Then, try to process a regular batch of messages
            fresh_runnables = claim_fresh_runnables(block: exponential_backoff)
            process_batch(fresh_runnables, reporter)

            # If we have acked the same amount of tests as we were supposed to, the run
            # is complete and we can exit our loop. Generally, only one worker will detect
            # this condition. The pther workers will quit their consumer loop because the
            # consumergroup will be deleted by the first worker, and their Redis commands
            # will start to fail - see the rescue block below.
            break if combined_results.complete?

            # We also abort a run if we reach the maximum number of failures
            break if combined_results.abort?

            # To make sure we don't end up in a busy loop overwhelming Redis with commands
            # when there is no work to do, we increase the blocking time exponentially,
            # and reset it to the initial value if we processed any tests.
            if stale_runnables.empty? && fresh_runnables.empty?
              exponential_backoff <<= 1
            else
              exponential_backoff = INITIAL_BACKOFF
            end
          end

          cleanup
        rescue Redis::CommandError => ce
          if ce.message.start_with?("NOGROUP")
            # When a redis conumer group commands fails with a NOGROUP error, we assume the
            # consumer group was deleted by the first worker that detected the run is complete.
            # So this worker can exit its loop as well.

            # We have to invalidate the local combined_results cache so we get fresh
            # final values from Redis when we try to report results in our summarizer.
            @combined_results = nil
          else
            raise
          end
        end

        private

        sig { returns(Redis) }
        def redis
          @redis ||= Redis.new(url: configuration.coordinator_uri.to_s)
        end

        sig { returns(String) }
        def register_consumergroup_script
          @register_consumergroup_script ||= T.let(redis.script(:load, <<~LUA), T.nilable(String))
            -- Try to create the consumergroup. This will raise an error if the
            -- consumergroup has already been registered by somebody else, which
            -- means another worker will be acting as leader.
            -- In that case, the next Redis DEL call will not be executed.
            redis.call('XGROUP', 'CREATE', KEYS[1], ARGV[1], '0', 'MKSTREAM')

            -- The leader should reset the size and acks key for this run attempt.
            -- We return the number of keys that were deleted, which can be used to
            -- determine whether this was the first attempt for this run or not.
            return redis.call('DEL', KEYS[2], KEYS[3])
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

        sig { void }
        def cleanup
          redis.xgroup(:destroy, stream_key, group_name)
          redis.del(stream_key)
        rescue Redis::CommandError
          # Apparently another consumer already removed the consumer group,
          # so we can assume that all the Redis cleanup was completed.
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
          end

          @combined_results = ResultAggregate.new(
            max_failures: configuration.max_failures,
            runs: updated[0],
            assertions: updated[1],
            passes: updated[2],
            failures: updated[3],
            errors: updated[4],
            skips: updated[5],
            requeues: updated[6],
            discards: updated[7],
            acks: updated[8],
            size: updated[9],
          )
        end

        sig { params(name: String).returns(String) }
        def key(name)
          "minitest/#{configuration.run_id}/#{name}"
        end

        sig { params(name: String).returns(String) }
        def list_key(name)
          key("#{name}_list")
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

          # Try to commit all the results of this batch to Redis
          runnable_results = []
          redis.multi do |pipeline|
            results.each do |enqueued_runnable, initial_result|
              runnable_results << enqueued_runnable.commit_result(initial_result) do |result_to_commit|
                if ResultType.of(result_to_commit) == ResultType::Requeued
                  sadd_future = pipeline.sadd(key("retry_set"), [enqueued_runnable.attempt_id])
                  EnqueuedRunnable::Result::Commit.new { sadd_future.value > 0 }
                else
                  xack_future = pipeline.xack(stream_key, group_name, enqueued_runnable.entry_id)
                  EnqueuedRunnable::Result::Commit.new { xack_future.value == 1 }
                end
              end
            end
          end

          batch_result_aggregate = ResultAggregate.new
          runnable_results.each do |runnable_result|
            # Complete the reporter contract by calling `record` with the result.
            reporter.record(runnable_result.committed_result)

            # Update statistics.
            batch_result_aggregate.update_with_result(runnable_result)
            local_results.update_with_result(runnable_result)

            case (result_type = ResultType.of(runnable_result.committed_result))
            when ResultType::Skipped, ResultType::Failed, ResultType::Error
              redis.lpush(list_key(result_type.serialize), runnable_result.enqueued_runnable.identifier)
            when ResultType::Passed, ResultType::Requeued, ResultType::Discarded
              # noop
            else
              T.absurd(result_type)
            end
          end

          adjust_combined_results(batch_result_aggregate)
        end

        INITIAL_BACKOFF = 10 # milliseconds
        private_constant :INITIAL_BACKOFF
      end
    end
  end
end
