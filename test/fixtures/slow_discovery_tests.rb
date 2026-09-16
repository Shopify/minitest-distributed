# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class SlowDiscoveryTests < Minitest::Test
  class << self
    def runnable_methods
      sleep(Float(ENV.fetch("DISCOVERY_SLEEP_TIME", "0.5")))
      super
    end
  end

  def test_passes
    pass
  end
end
