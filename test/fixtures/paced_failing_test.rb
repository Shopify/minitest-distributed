# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class PacedFailingTest < Minitest::Test
  def test_fails_after_delay
    sleep(Float(ENV.fetch("SLEEP_TIME", "0.2")))
    flunk
  end
end
