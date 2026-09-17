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
