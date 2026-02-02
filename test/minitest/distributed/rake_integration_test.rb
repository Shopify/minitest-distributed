# typed: true
# frozen_string_literal: true

require "test_helper"
require "rake"
require "rake/testtask"
require "minitest/distributed/rake_integration"

module Minitest
  module Distributed
    class RakeIntegrationTest < Minitest::Test
      def test_apply_sets_custom_loader
        task = Rake::TestTask.new(:test_integration) do |t|
          t.pattern = "test/fixtures/passing_tests.rb"
        end

        RakeIntegration.apply(task)

        assert_includes(task.run_code, "rake_test_loader.rb")
        assert(File.exist?(task.run_code.gsub('"', "")), "Loader file should exist")
      end

      def test_loader_path_is_correct
        expected_path = File.expand_path("../../../lib/minitest/distributed/rake_test_loader.rb", __dir__)
        assert_equal(expected_path, RakeIntegration::LOADER_PATH)
        assert(File.exist?(RakeIntegration::LOADER_PATH), "Loader file should exist at LOADER_PATH")
      end
    end

    class RakeTestLoaderTest < Minitest::Test
      LOADER_PATH = File.expand_path("../../../lib/minitest/distributed/rake_test_loader.rb", __dir__)
      FIXTURE_PATH = File.expand_path("../../fixtures/passing_tests.rb", __dir__)

      def test_loader_loads_files_without_lazy_load
        # Run loader in a subprocess without MINITEST_LAZY_LOAD
        output = run_loader_subprocess(lazy_load: false)

        # Should have loaded the file (class defined)
        assert_includes(output, "PassingTests class defined: true")
        # Should NOT have set MINITEST_TEST_FILES
        assert_includes(output, "MINITEST_TEST_FILES: empty")
      end

      def test_loader_defers_loading_with_lazy_load
        # Run loader in a subprocess with MINITEST_LAZY_LOAD=true
        output = run_loader_subprocess(lazy_load: true)

        # Should NOT have loaded the file (class not defined)
        assert_includes(output, "PassingTests class defined: false")
        # Should have set MINITEST_TEST_FILES
        assert_includes(output, "MINITEST_TEST_FILES: #{FIXTURE_PATH}")
      end

      private

      def run_loader_subprocess(lazy_load:)
        env = lazy_load ? { "MINITEST_LAZY_LOAD" => "true" } : {}

        # When lazy_load is true, the loader requires minitest/autorun which
        # registers an at_exit hook. We stub Minitest.autorun to prevent it
        # from actually running (we just want to test the loader's behavior).
        script = <<~RUBY
          # Prevent minitest from auto-running at exit
          module Minitest
            def self.autorun
              # no-op
            end
          end

          ARGV.replace([#{FIXTURE_PATH.inspect}])
          load #{LOADER_PATH.inspect}

          # Check if class was loaded
          class_defined = ObjectSpace.each_object(Class).any? { |c| c.name == "PassingTests" }
          puts "PassingTests class defined: \#{class_defined}"

          # Check MINITEST_TEST_FILES
          test_files = ENV["MINITEST_TEST_FILES"]
          puts "MINITEST_TEST_FILES: \#{test_files.to_s.empty? ? 'empty' : test_files}"
        RUBY

        IO.popen([env, RbConfig.ruby, "-e", script], &:read)
      end
    end
  end
end
