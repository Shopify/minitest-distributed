# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class FailingTests < Minitest::Test
  99.times do |i|
    define_method("test_pass_#{i}") { pass }
  end

  def test_fail
    flunk
  end
end
