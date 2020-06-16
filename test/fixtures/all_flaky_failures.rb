# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class TenFlakyFailures < Minitest::Test
  singleton_class.attr_accessor(:test_execution_index, :flaky_run)

  # We keep track of how many tests we have executed during a test run.
  self.test_execution_index = 0

  # We keep track whether this run is flaky (the first run) or not (second run)
  self.flaky_run = if ENV["FLAKY_TRACKER_FILE"] && File.exist?(ENV["FLAKY_TRACKER_FILE"])
    File.unlink(ENV["FLAKY_TRACKER_FILE"])
    true
  else
    false
  end

  100.times do |i|
    define_method("test_flaky_fail_#{i}") do
      TenFlakyFailures.test_execution_index += 1

      if TenFlakyFailures.test_execution_index <= 10
        # The first 10 tests will be flaky, and will succeed on the second run
        TenFlakyFailures.flaky_run ? flunk : pass
      elsif TenFlakyFailures.test_execution_index == 11
        # The 11th test always fails
        flunk
      else
        # All subsequent tests will succeed
        pass
      end
    end
  end
end
