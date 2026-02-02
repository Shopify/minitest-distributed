# typed: true
# frozen_string_literal: true

require "test_helper"

module Minitest
  module Distributed
    class TestSelectorTest < Minitest::Test
      def test_test_manifest_returns_class_to_file_mapping
        options = {
          filter: nil,
          exclude: nil,
          distributed: Configuration.new,
        }
        test_selector = TestSelector.new(options)

        manifest = test_selector.test_manifest

        assert_kind_of(Hash, manifest)

        # The manifest should contain at least this test class
        assert_includes(manifest.keys, "Minitest::Distributed::TestSelectorTest")

        # The file path should end with this test file
        file_path = manifest["Minitest::Distributed::TestSelectorTest"]
        assert(file_path.end_with?("test/minitest/distributed/test_selector_test.rb"), "Expected path to end with test file")
      end

      def test_test_manifest_returns_same_object_on_subsequent_calls
        options = {
          filter: nil,
          exclude: nil,
          distributed: Configuration.new,
        }
        test_selector = TestSelector.new(options)

        manifest1 = test_selector.test_manifest
        manifest2 = test_selector.test_manifest

        assert_same(manifest1, manifest2)
      end

      def test_test_manifest_warns_on_duplicate_class_names
        # Create two mock runnable classes with the same name but different source locations
        mock_class1 = Class.new(Minitest::Test) do
          def self.name
            "DuplicateTestClass"
          end

          def self.runnable_methods
            ["test_from_file1"]
          end
        end

        mock_class2 = Class.new(Minitest::Test) do
          def self.name
            "DuplicateTestClass"
          end

          def self.runnable_methods
            ["test_from_file2"]
          end
        end

        # Stub source_location to return different files
        mock_class1.define_method(:test_from_file1) {}
        mock_class2.define_method(:test_from_file2) {}

        options = {
          filter: nil,
          exclude: nil,
          distributed: Configuration.new,
        }
        test_selector = TestSelector.new(options)

        # Stub runnables to return our mock classes
        test_selector.stub(:runnables, [mock_class1, mock_class2]) do
          # Stub source_location_for to return different paths
          test_selector.stub(:source_location_for, ->(klass) {
            klass == mock_class1 ? "/path/to/file1.rb" : "/path/to/file2.rb"
          }) do
            warning_output = capture_io do
              test_selector.test_manifest
            end[1] # stderr is second element

            assert_includes(warning_output, "WARNING: Duplicate class name 'DuplicateTestClass'")
            assert_includes(warning_output, "/path/to/file1.rb")
            assert_includes(warning_output, "/path/to/file2.rb")
          end
        end
      end

      def test_test_manifest_no_warning_for_unique_class_names
        options = {
          filter: nil,
          exclude: nil,
          distributed: Configuration.new,
        }
        test_selector = TestSelector.new(options)

        warning_output = capture_io do
          test_selector.test_manifest
        end[1] # stderr

        refute_includes(warning_output, "WARNING: Duplicate class name")
      end
    end
  end
end
