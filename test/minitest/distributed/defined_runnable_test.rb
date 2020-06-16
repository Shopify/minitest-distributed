# typed: true
# frozen_string_literal: true

require "test_helper"

module Minitest
  module Distributed
    class DefinedRunnableTest < Minitest::Test
      def test_find_class
        runnable = DefinedRunnable.find_class("Minitest::Distributed::DefinedRunnableTest")
        assert_equal(DefinedRunnableTest, runnable)

        assert_raises(TypeError) do
          DefinedRunnable.find_class("Minitest::Distributed::EnqueuedRunnable")
        end
      end
    end
  end
end
