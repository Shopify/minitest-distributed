# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class FlakyTest < Minitest::Test
  99.times do |i|
    define_method("test_pass_#{i}") { pass }
  end

  def test_flaky
    if ENV["FLAKY_TRACKER_FILE"] && File.exist?(ENV["FLAKY_TRACKER_FILE"])
      File.unlink(ENV["FLAKY_TRACKER_FILE"])
      flunk("Flaky failure")
    else
      pass
    end
  end
end
