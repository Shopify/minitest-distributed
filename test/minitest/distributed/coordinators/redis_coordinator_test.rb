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
