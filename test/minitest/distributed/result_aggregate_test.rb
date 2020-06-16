# typed: true
# frozen_string_literal: true

require "test_helper"

module Minitest
  module Distributed
    class ResultAggregateTest < Minitest::Test
      def test_complete?
        assert_predicate(ResultAggregate.new, :complete?)
        assert_predicate(ResultAggregate.new(size: 0, acks: 0), :complete?)
        assert_predicate(ResultAggregate.new(size: 10, acks: 10), :complete?)
        refute_predicate(ResultAggregate.new(size: 10, acks: 0), :complete?)
        refute_predicate(ResultAggregate.new(size: 10, acks: 11), :complete?)
      end

      def test_valid?
        assert_predicate(ResultAggregate.new, :valid?)
        assert_predicate(ResultAggregate.new(runs: 100, passes: 100), :valid?)
        assert_predicate(ResultAggregate.new(runs: 102, passes: 100, requeues: 2), :valid?)
        assert_predicate(ResultAggregate.new(runs: 100, passes: 98, discards: 2), :valid?)
        assert_predicate(ResultAggregate.new(runs: 100, passes: 99, failures: 1), :valid?)
        assert_predicate(ResultAggregate.new(runs: 4, passes: 1, failures: 1, errors: 1, skips: 1), :valid?)

        refute_predicate(ResultAggregate.new(runs: 1), :valid?)
        refute_predicate(ResultAggregate.new(runs: 1, passes: 2), :valid?)
        refute_predicate(ResultAggregate.new(runs: 1, passes: 1, requeues: 1), :valid?)
        refute_predicate(ResultAggregate.new(runs: 1, passes: 1, discards: 1), :valid?)
      end

      def test_passed?
        assert_predicate(ResultAggregate.new, :passed?)
        assert_predicate(ResultAggregate.new(runs: 100, passes: 100), :passed?)
        assert_predicate(ResultAggregate.new(runs: 100, passes: 99, skips: 1), :passed?)
        assert_predicate(ResultAggregate.new(runs: 102, passes: 100, requeues: 2), :passed?)

        refute_predicate(ResultAggregate.new(runs: 100, passes: 99, errors: 1), :passed?)
        refute_predicate(ResultAggregate.new(runs: 100, passes: 99, failures: 1), :passed?)
      end
    end
  end
end
