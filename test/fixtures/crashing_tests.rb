# typed: false
# frozen_string_literal: true

require "minitest/autorun"

class CrashingTest < Minitest::Test
  99.times do |i|
    define_method("test_pass_#{i}") { pass }
  end

  def test_crash
    if ENV["CRASH_TRACKER_FILE"] && File.exist?(ENV["CRASH_TRACKER_FILE"])
      File.unlink(ENV["CRASH_TRACKER_FILE"])
      Process.kill("KILL", Process.pid)
    else
      pass
    end
  end
end
