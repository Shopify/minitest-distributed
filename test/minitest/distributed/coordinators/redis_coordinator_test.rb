# typed: true
# frozen_string_literal: true

require "test_helper"

module Minitest
  module Distributed
    module Coordinators
      class RedisCoordinatorTest < Minitest::Test
        # Mirror of the private constants from RedisCoordinator. The behavior
        # tests below also exercise the cap, so any drift in the production
        # value (e.g. MAX_BACKOFF moves up or down) will fail those tests.
        EXPECTED_INITIAL_BACKOFF = 10 # milliseconds
        EXPECTED_MAX_BACKOFF = 5_000 # milliseconds

        def setup
          @coordinator = RedisCoordinator.new(
            configuration: Configuration.new(
              coordinator_uri: URI("redis://localhost/0"),
              run_id: "test_next_backoff",
            ),
          )
        end

        def test_next_backoff_doubles_below_max
          assert_equal(20, @coordinator.send(:next_backoff, 10))
          assert_equal(40, @coordinator.send(:next_backoff, 20))
          assert_equal(2_560, @coordinator.send(:next_backoff, 1_280))
        end

        def test_next_backoff_clamps_at_max
          # Last doubling that stays at or under the cap.
          assert_operator(@coordinator.send(:next_backoff, EXPECTED_MAX_BACKOFF / 2), :<=, EXPECTED_MAX_BACKOFF)
          # Doubling that would exceed the cap stays at the cap.
          assert_equal(EXPECTED_MAX_BACKOFF, @coordinator.send(:next_backoff, EXPECTED_MAX_BACKOFF))
          assert_equal(EXPECTED_MAX_BACKOFF, @coordinator.send(:next_backoff, EXPECTED_MAX_BACKOFF * 2))
          assert_equal(EXPECTED_MAX_BACKOFF, @coordinator.send(:next_backoff, 1_000_000))
        end

        def test_consume_routes_backoff_through_next_backoff_and_caps_at_max
          # Pins the call site of `next_backoff` inside `consume`'s idle-loop path.
          # Without this test the helper assertions above still pass even if the
          # `consume` loop reverts to a bare `exponential_backoff <<= 1`, which is
          # exactly the regression this PR is preventing. We assert that the `block:`
          # argument actually passed to `claim_fresh_runnables` saturates at
          # `MAX_BACKOFF`; a revert to unbounded doubling would push the captured
          # value past 5_000_000 within 20 idle iterations.
          captured_blocks = T.let([], T::Array[Integer])
          remaining_idle_iterations = T.let(25, Integer)

          @coordinator.define_singleton_method(:claim_stale_runnables) { [] }
          @coordinator.define_singleton_method(:claim_fresh_runnables) do |block:|
            captured_blocks << block
            []
          end
          @coordinator.define_singleton_method(:process_batch) { |*_| }
          @coordinator.define_singleton_method(:cleanup) {}
          @coordinator.define_singleton_method(:current_production_heartbeat) { nil }
          @coordinator.define_singleton_method(:run_complete?, &:complete?)

          fake_results = Object.new
          fake_results.define_singleton_method(:complete?) do
            remaining_idle_iterations -= 1
            remaining_idle_iterations <= 0
          end
          fake_results.define_singleton_method(:abort?) { false }
          fake_results.define_singleton_method(:acks) { 0 }
          fake_results.define_singleton_method(:size) { 1 }
          @coordinator.define_singleton_method(:combined_results) { fake_results }

          @coordinator.consume(reporter: Minitest::CompositeReporter.new)

          assert_operator(
            captured_blocks.length,
            :>=,
            20,
            "Expected consume to run enough idle iterations to saturate the backoff; got #{captured_blocks.length}.",
          )
          # Once the backoff reaches MAX_BACKOFF it must stay there. The last five
          # captures pin the call site: if it were `<<= 1`, these would be growing
          # powers of two well above MAX_BACKOFF rather than the cap itself.
          assert_equal([EXPECTED_MAX_BACKOFF] * 5, captured_blocks.last(5))
        end

        def test_pre_publish_zero_work_snapshot_does_not_trigger_max_failures_truncation
          stale_claim_calls = 0
          marked_truncated = T.let(false, T::Boolean)
          fake_results = Object.new
          fake_results.define_singleton_method(:complete?) { true }
          fake_results.define_singleton_method(:abort?) { true }
          fake_results.define_singleton_method(:acks) { 0 }
          fake_results.define_singleton_method(:size) { 0 }

          @coordinator.define_singleton_method(:claim_stale_runnables) do
            stale_claim_calls += 1
            raise "stop consume" if stale_claim_calls > 1

            []
          end
          @coordinator.define_singleton_method(:claim_fresh_runnables) { |**_kwargs| [] }
          @coordinator.define_singleton_method(:combined_results) { fake_results }
          @coordinator.define_singleton_method(:run_complete?) { |*_args| false }
          @coordinator.define_singleton_method(:current_production_heartbeat) { nil }
          @coordinator.define_singleton_method(:mark_run_truncated) { marked_truncated = true }

          assert_raises(RuntimeError) do
            @coordinator.consume(reporter: Minitest::CompositeReporter.new)
          end
          refute(marked_truncated)
        end

        def test_consume_does_not_classify_application_argument_errors_as_coordinator_corruption
          @coordinator.define_singleton_method(:combined_results) do
            ResultAggregate.new(acks: 0, size: 1)
          end
          @coordinator.define_singleton_method(:current_production_heartbeat) { nil }
          @coordinator.define_singleton_method(:claim_stale_runnables) { [Object.new] }
          @coordinator.define_singleton_method(:process_batch) do |*_args|
            raise ArgumentError, "application bug"
          end

          error = T.let(nil, T.nilable(ArgumentError))
          begin
            @coordinator.consume(reporter: Minitest::CompositeReporter.new)
          rescue ArgumentError => raised_error
            error = raised_error
          end
          assert_equal("application bug", T.must(error).message)
          refute_predicate(@coordinator, :aborted?)
        end

        def test_consume_invalidates_memoized_results_before_polling
          observed_cache = T.let(Object.new, T.untyped)
          cached_results = ResultAggregate.new(acks: 0, size: 1)
          T.unsafe(@coordinator).instance_variable_set(:@combined_results, cached_results)
          @coordinator.define_singleton_method(:current_production_heartbeat) { nil }
          @coordinator.define_singleton_method(:claim_stale_runnables) do
            observed_cache = instance_variable_get(:@combined_results)
            raise "stop consume"
          end

          assert_raises(RuntimeError) do
            @coordinator.consume(reporter: Minitest::CompositeReporter.new)
          end
          assert_nil(observed_cache)
        end

        def test_mutating_scripts_disable_transparent_reconnect_replay
          mutation_count = 0
          reconnect_disabled = T.let(false, T::Boolean)
          fake_redis = Redis.allocate
          fake_redis.define_singleton_method(:without_reconnect) do |&block|
            reconnect_disabled = true
            block.call
          ensure
            reconnect_disabled = false
          end
          fake_redis.define_singleton_method(:evalsha) do |*_args, **_kwargs|
            mutation_count += 1
            mutation_count += 1 unless reconnect_disabled # Simulate redis-rb replay after a lost response.
            raise Redis::ConnectionError, "response lost after execution"
          end
          T.unsafe(@coordinator).instance_variable_set(:@redis, fake_redis)
          T.unsafe(@coordinator).instance_variable_set(:@adjust_results_script, "loaded-sha")

          assert_raises(Redis::ConnectionError) do
            T.unsafe(@coordinator).send(:execute_script, script_name: :adjust_results, keys: [], argv: [])
          end
          assert_equal(1, mutation_count)
        end

        def test_mutating_without_reconnect_scopes_are_serialized_across_threads
          active_scopes = 0
          max_active_scopes = 0
          scope_lock = Mutex.new
          fake_redis = Redis.allocate
          fake_redis.define_singleton_method(:without_reconnect) do |&block|
            scope_lock.synchronize do
              active_scopes += 1
              max_active_scopes = [max_active_scopes, active_scopes].max
            end
            sleep(0.02)
            block.call
          ensure
            scope_lock.synchronize { active_scopes -= 1 }
          end
          fake_redis.define_singleton_method(:evalsha) { |*_args, **_kwargs| 0 }
          T.unsafe(@coordinator).instance_variable_set(:@redis, fake_redis)
          T.unsafe(@coordinator).instance_variable_set(:@adjust_results_script, "loaded-sha")

          threads = 2.times.map do
            Thread.new do
              T.unsafe(@coordinator).send(:execute_script, script_name: :adjust_results, keys: [], argv: [])
            end
          end
          threads.each(&:join)

          assert_equal(1, max_active_scopes)
        end

        def test_mutating_script_load_is_serialized_with_no_reconnect_scopes
          load_started = Queue.new
          release_load = Queue.new
          entered_no_reconnect = Queue.new
          fake_redis = Redis.allocate
          fake_redis.define_singleton_method(:script) do |*_args|
            load_started.push(true)
            release_load.pop
            "loaded-adjust-sha"
          end
          fake_redis.define_singleton_method(:without_reconnect) do |&block|
            entered_no_reconnect.push(true)
            block.call
          end
          fake_redis.define_singleton_method(:evalsha) { |*_args, **_kwargs| 0 }
          T.unsafe(@coordinator).instance_variable_set(:@redis, fake_redis)
          T.unsafe(@coordinator).instance_variable_set(:@heartbeat_script, "loaded-heartbeat-sha")

          loading_thread = Thread.new do
            T.unsafe(@coordinator).send(:execute_script, script_name: :adjust_results, keys: [], argv: [])
          end
          load_started.pop
          heartbeat_thread = Thread.new do
            T.unsafe(@coordinator).send(:execute_script, script_name: :heartbeat, keys: [], argv: [])
          end
          sleep(0.05)
          entered_before_load_finished = !entered_no_reconnect.empty?
          release_load.push(true)
          loading_thread.join
          heartbeat_thread.join

          refute(entered_before_load_finished)
        end

        def test_truncated_follower_skips_the_consumer_loop
          T.unsafe(@coordinator).instance_variable_set(:@truncated_follower, true)
          @coordinator.define_singleton_method(:claim_stale_runnables) { raise "consumer loop entered" }

          @coordinator.consume(reporter: Minitest::CompositeReporter.new)
          assert(true)
        end

        def test_production_heartbeat_retries_transient_connection_errors
          attempts = 0
          @coordinator.configuration.stall_timeout_seconds = 0.02
          T.unsafe(@coordinator).instance_variable_set(:@attempt_generation, "generation")
          @coordinator.define_singleton_method(:execute_script) do |**_kwargs|
            attempts += 1
            raise Redis::CannotConnectError, "temporary failure" if attempts == 1

            0
          end

          thread = T.cast(@coordinator.send(:start_production_heartbeat), Thread)
          thread.join(1)
          @coordinator.send(:stop_production_heartbeat, thread, propagate_error: true)

          assert_equal(2, attempts)
        end

        def test_production_heartbeat_surfaces_non_connection_errors
          @coordinator.configuration.stall_timeout_seconds = 0.02
          T.unsafe(@coordinator).instance_variable_set(:@attempt_generation, "generation")
          @coordinator.define_singleton_method(:execute_script) do |**_kwargs|
            raise Redis::CommandError, "invalid heartbeat state"
          end

          thread = T.cast(@coordinator.send(:start_production_heartbeat), Thread)
          thread.join(1)
          assert_raises(Redis::CommandError) do
            @coordinator.send(:stop_production_heartbeat, thread, propagate_error: true)
          end
        end

        def test_parse_redis_integer_rejects_negative_and_unsafe_values
          max_safe = 9_007_199_254_740_991

          assert_equal(max_safe, @coordinator.send(:parse_redis_integer, max_safe.to_s))
          assert_nil(@coordinator.send(:parse_redis_integer, (max_safe + 1).to_s))
          assert_nil(@coordinator.send(:parse_redis_integer, "-1"))
        end

        def test_run_completion_uses_production_state_from_the_same_snapshot
          results = ResultAggregate.new(acks: 0, size: 0)
          T.unsafe(@coordinator).instance_variable_set(:@combined_results, results)
          T.unsafe(@coordinator).instance_variable_set(:@combined_results_production_complete, false)

          refute(@coordinator.send(:run_complete?, results))

          T.unsafe(@coordinator).instance_variable_set(:@combined_results_production_complete, true)
          assert(@coordinator.send(:run_complete?, results))
        end

        def test_truncated_cleanup_race_aborts_locally_without_marking_shared_state_stalled
          local_diagnostic = T.let(nil, T.nilable(String))
          shared_abort_called = T.let(false, T::Boolean)
          @coordinator.define_singleton_method(:attempt_superseded?) { false }
          @coordinator.define_singleton_method(:attempt_truncated?) { true }
          @coordinator.define_singleton_method(:abort_locally_with_diagnostic) do |diagnostic|
            local_diagnostic = diagnostic
          end
          @coordinator.define_singleton_method(:abort_with_diagnostic) { |*_args| shared_abort_called = true }

          @coordinator.send(:handle_coordinator_state_error, Redis::CommandError.new("NOGROUP missing group"))

          assert_includes(T.must(local_diagnostic), "another worker truncated the run")
          refute(shared_abort_called)
        end

        def test_wrongtype_error_is_not_suppressed_by_terminal_counters
          aborted_with = T.let(nil, T.nilable(String))
          complete_results = ResultAggregate.new(acks: 0, size: 0)
          T.unsafe(@coordinator).instance_variable_set(:@combined_results, complete_results)
          T.unsafe(@coordinator).instance_variable_set(:@combined_results_production_complete, true)
          @coordinator.define_singleton_method(:attempt_superseded?) { false }
          @coordinator.define_singleton_method(:attempt_truncated?) { false }
          @coordinator.define_singleton_method(:combined_results) do
            instance_variable_set(:@combined_results, complete_results)
            instance_variable_set(:@combined_results_production_complete, true)
            complete_results
          end
          @coordinator.define_singleton_method(:abort_with_diagnostic) { |diagnostic| aborted_with = diagnostic }

          @coordinator.send(:handle_coordinator_state_error, Redis::CommandError.new("WRONGTYPE invalid stream"))

          assert_includes(T.must(aborted_with), "lost required Redis coordinator state")
        end

        def test_coordinator_error_is_not_suppressed_by_incomplete_max_failure_state
          aborted_with = T.let(nil, T.nilable(String))
          incomplete_results = ResultAggregate.new(max_failures: 1, failures: 1, acks: 0, size: 2)
          @coordinator.define_singleton_method(:attempt_superseded?) { false }
          @coordinator.define_singleton_method(:attempt_truncated?) { false }
          @coordinator.define_singleton_method(:combined_results) { incomplete_results }
          @coordinator.define_singleton_method(:run_complete?) { |*_args| false }
          @coordinator.define_singleton_method(:abort_with_diagnostic) { |diagnostic| aborted_with = diagnostic }

          @coordinator.send(:handle_coordinator_state_error, Redis::CommandError.new("NOGROUP missing group"))

          assert_includes(T.must(aborted_with), "lost required Redis coordinator state")
        end

        def test_next_backoff_caps_within_a_bounded_number_of_iterations
          # Sanity check the doubling math: starting from INITIAL_BACKOFF, the cap must
          # be reached within a small, bounded number of iterations so that consume()
          # can re-evaluate `complete?` / `abort?` within MAX_BACKOFF of run completion.
          backoff = T.let(EXPECTED_INITIAL_BACKOFF, Integer)
          iterations = 0
          while backoff < EXPECTED_MAX_BACKOFF
            backoff = T.cast(@coordinator.send(:next_backoff, backoff), Integer)
            iterations += 1
            break if iterations > 64 # guard against an unbounded test loop
          end
          assert_equal(EXPECTED_MAX_BACKOFF, backoff)
          assert_operator(
            iterations,
            :<=,
            20,
            "Expected the backoff to cap within ~20 doublings; got #{iterations}",
          )
        end
      end
    end
  end
end
