# typed: true
# frozen_string_literal: true

require "minitest/autorun"

class JunitReporterTest < Minitest::Test
  def test_pass
    pass
  end

  def test_crash
    raise "Epic fail"
  end

  def test_fail
    flunk
  end
end
