# typed: true
# frozen_string_literal: true

require "minitest/autorun"

class ASuite < Minitest::Test
  def test_a
    pass
  end
end

class BSuite < Minitest::Test
  def test_b
    pass
  end
end
