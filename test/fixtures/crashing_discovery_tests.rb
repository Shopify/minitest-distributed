# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class CrashingDiscoveryTests < Minitest::Test
  class << self
    def runnable_methods
      sleep(Float(ENV.fetch("DISCOVERY_SLEEP_TIME", "0.2")))
      exit!(2)
    end
  end

  def test_never_runs
    flunk
  end
end
