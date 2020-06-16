# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class SlowTest < Minitest::Test
  99.times do |i|
    define_method("test_pass_#{i}") { pass }
  end

  def test_too_slow
    sleep_time = Float(ENV.fetch("SLEEP_TIME", "1.0"))
    sleep(sleep_time)
    pass
  end
end
