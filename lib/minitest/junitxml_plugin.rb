# typed: true
# frozen_string_literal: true

module Minitest
  class << self
    def plugin_junitxml_options(opts, options)
      options[:junitxml] = ENV["MINITEST_JUNITXML"]

      opts.on("--junitxml=PATH", "Generate a JUnitXML report at the specified path") do |path|
        options[:junitxml] = path
      end
    end

    def plugin_junitxml_init(options)
      return if options[:junitxml].nil?

      require "minitest/distributed/reporters/junitxml_reporter"
      reporter << Minitest::Distributed::Reporters::JUnitXMLReporter.new(options[:io], options)
    end
  end
end
