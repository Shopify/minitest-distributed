# typed: true
# frozen_string_literal: true

require "test_helper"

module Minitest
  module Distributed
    class ConfigurationTest < Minitest::Test
      def test_lazy_load_defaults_to_false
        config = Configuration.new
        refute(config.lazy_load)
      end

      def test_test_helpers_defaults_to_empty_array
        config = Configuration.new
        assert_empty(config.test_helpers)
      end

      def test_from_env_with_lazy_load_true
        env = {
          "MINITEST_LAZY_LOAD" => "true",
        }
        config = Configuration.from_env(env)
        assert(config.lazy_load)
      end

      def test_from_env_with_lazy_load_false
        env = {
          "MINITEST_LAZY_LOAD" => "false",
        }
        config = Configuration.from_env(env)
        refute(config.lazy_load)
      end

      def test_from_env_with_test_helpers
        env = {
          "MINITEST_TEST_HELPERS" => "test/test_helper.rb, test/support/helpers.rb",
        }
        config = Configuration.from_env(env)
        assert_equal(["test/test_helper.rb", "test/support/helpers.rb"], config.test_helpers)
      end

      def test_from_env_with_empty_test_helpers
        env = {}
        config = Configuration.from_env(env)
        assert_empty(config.test_helpers)
      end

      def test_test_files_defaults_to_empty_array
        config = Configuration.new
        assert_empty(config.test_files)
      end

      def test_from_env_with_test_files
        env = {
          "MINITEST_TEST_FILES" => "/path/to/test1.rb, /path/to/test2.rb",
        }
        config = Configuration.from_env(env)
        assert_equal(["/path/to/test1.rb", "/path/to/test2.rb"], config.test_files)
      end

      def test_from_env_with_empty_test_files
        env = {}
        config = Configuration.from_env(env)
        assert_empty(config.test_files)
      end
    end
  end
end
