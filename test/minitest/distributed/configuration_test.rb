# typed: true
# frozen_string_literal: true

require "test_helper"

module Minitest
  module Distributed
    class ConfigurationTest < Minitest::Test
      def test_rejects_non_positive_key_ttl
        configuration = Configuration.new(key_ttl_seconds: 0)

        assert_raises(ArgumentError) { configuration.coordinator }
      end

      def test_rejects_non_positive_stall_timeout
        configuration = Configuration.new(stall_timeout_seconds: 0.0)

        assert_raises(ArgumentError) { configuration.coordinator }
      end

      def test_rejects_non_finite_stall_timeout
        configuration = Configuration.new(stall_timeout_seconds: Float::INFINITY)

        assert_raises(ArgumentError) { configuration.coordinator }
      end
    end
  end
end
