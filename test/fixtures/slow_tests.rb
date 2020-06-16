# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class SlowTests < Minitest::Test
  97.times do |i|
    define_method("test_slow_pass_#{i}") do
      sleep(0.1)
      pass
    end
  end

  def test_slow_fail
    sleep(0.1)
    flunk
  end

  def test_slow_error
    sleep(0.1)
    raise RuntimeError
  end

  def test_slow_skip
    sleep(0.1)
    skip("Nothing to see here")
  end
end
