# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class ManyFailingTests < Minitest::Test
  50.times do |i|
    define_method("test_pass_#{i}") { pass }
  end

  25.times do |i|
    define_method("test_fail_#{i}") { flunk }
  end

  25.times do |i|
    define_method("test_raise_#{i}") { raise "Epic fail" }
  end
end
