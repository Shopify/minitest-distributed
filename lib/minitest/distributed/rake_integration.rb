# typed: true
# frozen_string_literal: true

require "rake/testtask"

module Minitest
  module Distributed
    # Configures Rake::TestTask for lazy loading support.
    #
    # @example
    #   Rake::TestTask.new do |t|
    #     t.pattern = "test/**/*_test.rb"
    #     Minitest::Distributed::RakeIntegration.apply(t)
    #   end
    module RakeIntegration
      LOADER_PATH = File.expand_path("rake_test_loader.rb", __dir__)

      class << self
        # @param task [Rake::TestTask]
        # @return [Rake::TestTask]
        def apply(task)
          task.loader = :direct
          task.define_singleton_method(:run_code) { %("#{LOADER_PATH}") }
          task
        end
      end
    end
  end
end
