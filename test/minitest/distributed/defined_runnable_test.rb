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

      def test_class_defined_returns_true_for_defined_class
        assert(DefinedRunnable.class_defined?("Minitest::Distributed::DefinedRunnableTest"))
        assert(DefinedRunnable.class_defined?("Minitest::Test"))
        assert(DefinedRunnable.class_defined?("Object"))
      end

      def test_class_defined_returns_false_for_undefined_class
        refute(DefinedRunnable.class_defined?("NonExistent::Class"))
        refute(DefinedRunnable.class_defined?("Minitest::NonExistentClass"))
      end

      def test_load_class_from_manifest_raises_when_class_not_in_manifest
        manifest = {}

        error = assert_raises(LazyLoadError) do
          DefinedRunnable.load_class_from_manifest("NonExistent::Class", manifest)
        end

        assert_includes(error.message, "Cannot find test file for class 'NonExistent::Class'")
      end

      def test_load_class_from_manifest_loads_file
        # Use the fixture file path - load will execute it even if already loaded
        fixture_path = File.expand_path("../../fixtures/passing_tests.rb", __dir__)
        manifest = {
          "PassingTests" => fixture_path,
        }

        # Should not raise - load always executes the file
        DefinedRunnable.load_class_from_manifest("PassingTests", manifest)

        # Verify the class is now properly defined
        assert(DefinedRunnable.class_defined?("PassingTests"))
      end
    end
  end
end
