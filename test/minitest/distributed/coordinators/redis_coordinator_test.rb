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
        EXPECTED_SCRIPT_LOAD_MAX_ATTEMPTS = 3
        EXPECTED_SCRIPT_LOAD_RETRY_DELAY = 1 # second

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

          fake_results = Object.new
          fake_results.define_singleton_method(:complete?) do
            remaining_idle_iterations -= 1
            remaining_idle_iterations <= 0
          end
          fake_results.define_singleton_method(:abort?) { false }
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

        def test_register_consumergroup_script_retries_connection_failures
          attempts = 0
          redis = Object.new
          redis.define_singleton_method(:script) do |_command, _script|
            attempts += 1
            raise Redis::CannotConnectError, "connection timed out" if attempts < EXPECTED_SCRIPT_LOAD_MAX_ATTEMPTS

            "script-sha"
          end
          sleeps = []

          @coordinator.define_singleton_method(:redis) { redis }
          @coordinator.define_singleton_method(:sleep) { |delay| sleeps << delay }

          assert_equal("script-sha", @coordinator.send(:register_consumergroup_script))
          assert_equal(EXPECTED_SCRIPT_LOAD_MAX_ATTEMPTS, attempts)
          assert_equal(
            [EXPECTED_SCRIPT_LOAD_RETRY_DELAY] * (EXPECTED_SCRIPT_LOAD_MAX_ATTEMPTS - 1),
            sleeps,
          )
        end

        def test_register_consumergroup_script_does_not_retry_read_timeouts
          attempts = 0
          redis = Object.new
          redis.define_singleton_method(:script) do |_command, _script|
            attempts += 1
            raise Redis::TimeoutError, "read timed out"
          end

          @coordinator.define_singleton_method(:redis) { redis }

          assert_raises(Redis::TimeoutError) do
            @coordinator.send(:register_consumergroup_script)
          end
          assert_equal(1, attempts)
        end

        def test_register_consumergroup_script_stops_retrying_connection_failures
          attempts = 0
          redis = Object.new
          redis.define_singleton_method(:script) do |_command, _script|
            attempts += 1
            raise Redis::CannotConnectError, "connection timed out"
          end
          sleeps = []

          @coordinator.define_singleton_method(:redis) { redis }
          @coordinator.define_singleton_method(:sleep) { |delay| sleeps << delay }

          assert_raises(Redis::CannotConnectError) do
            @coordinator.send(:register_consumergroup_script)
          end
          assert_equal(EXPECTED_SCRIPT_LOAD_MAX_ATTEMPTS, attempts)
          assert_equal(
            [EXPECTED_SCRIPT_LOAD_RETRY_DELAY] * (EXPECTED_SCRIPT_LOAD_MAX_ATTEMPTS - 1),
            sleeps,
          )
        end
      end
    end
  end
end
