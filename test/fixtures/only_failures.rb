# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class OnlyFailures < Minitest::Test
  100.times do |i|
    define_method("test_fail_#{i}") { flunk }
  end
end
