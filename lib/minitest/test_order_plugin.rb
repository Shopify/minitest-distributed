# typed: true
# frozen_string_literal: true

module Minitest
  class << self
    def plugin_test_order_options(opts, options)
      options[:test_order_file] = ENV["MINITEST_TEST_ORDER"]

      opts.on("--test_order=PATH", "Log order of tests executed to provided file.") do |path|
        options[:test_order_file] = path
      end
    end

    def plugin_test_order_init(options)
      return if options[:test_order_file].nil?

      require_relative "distributed/reporters/test_order_reporter"
      reporter << Minitest::Distributed::Reporters::TestOrderReporter.new(options[:io], options)
    end
  end
end
