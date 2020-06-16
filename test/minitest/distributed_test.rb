# typed: true
# frozen_string_literal: true

require "test_helper"

module Minitest
  class DistributedTest < Minitest::Test
    def test_that_it_has_a_version_number
      refute_nil(::Minitest::Distributed::VERSION)
    end
  end
end
