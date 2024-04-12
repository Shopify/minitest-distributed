# typed: true
# frozen_string_literal: true

require_relative "distributed"

module Minitest
  class << self
    extend T::Sig

    def plugin_distributed_options(opts, options)
      continuous_integration = ENV.fetch("CI", "false") == "true"
      options[:disable_distributed] = !continuous_integration

      opts.on("--disable-distributed", "Disable the distributed plugin") do
        options[:disable_distributed] = true
      end

      opts.on("--enable-distributed", "Enable the distributed plugin") do
        options[:disable_distributed] = false
      end

      options[:distributed] = Minitest::Distributed::Configuration.from_command_line_options(opts, options)
    end

    def plugin_distributed_init(options)
      return if options[:disable_distributed]

      Minitest.singleton_class.prepend(Minitest::Distributed::TestRunnerPatch)

      remove_reporter(::Rails::TestUnitReporter) if defined?(::Rails::TestUnitReporter)
      remove_reporter(Minitest::ProgressReporter)
      remove_reporter(Minitest::SummaryReporter)

      options[:distributed].coordinator.register_reporters(reporter: reporter, options: options)

      reporter << Minitest::Distributed::Reporters::DistributedPogressReporter.new(options[:io], options)
      reporter << Minitest::Distributed::Reporters::DistributedSummaryReporter.new(options[:io], options)
    end

    private

    def remove_reporter(reporter_class)
      reporter.reporters.reject! { |reporter| reporter.is_a?(reporter_class) }
    end
  end
end
