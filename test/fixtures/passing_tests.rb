# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class PassingTests < Minitest::Test
  100.times do |i|
    define_method("test_pass_#{i}") { pass }
  end
end
