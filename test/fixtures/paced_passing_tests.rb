# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class PacedPassingTests < Minitest::Test
  20.times do |i|
    define_method("test_pass_#{i}") do
      sleep(0.02)
      pass
    end
  end
end
