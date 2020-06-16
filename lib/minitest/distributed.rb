# typed: strict
# frozen_string_literal: true

require "minitest"
require "sorbet-runtime"

require "minitest/distributed/configuration"
require "minitest/distributed/test_runner"
require "minitest/distributed/test_selector"
require "minitest/distributed/enqueued_runnable"
require "minitest/distributed/result_type"
require "minitest/distributed/result_aggregate"
require "minitest/distributed/filters/filter_interface"
require "minitest/distributed/filters/include_filter"
require "minitest/distributed/filters/exclude_filter"
require "minitest/distributed/filters/file_filter_base"
require "minitest/distributed/filters/exclude_file_filter"
require "minitest/distributed/filters/include_file_filter"
require "minitest/distributed/coordinators/coordinator_interface"
require "minitest/distributed/coordinators/memory_coordinator"
require "minitest/distributed/coordinators/redis_coordinator"
require "minitest/distributed/reporters/redis_coordinator_warnings_reporter"
require "minitest/distributed/reporters/distributed_progress_reporter"
require "minitest/distributed/reporters/distributed_summary_reporter"

module Minitest
  module Distributed
    class Error < StandardError; end

    module TestRunnerPatch
      extend T::Sig

      sig { params(reporter: Minitest::AbstractReporter, options: T::Hash[Symbol, T.untyped]).void }
      def __run(reporter, options)
        TestRunner.new(options).run(reporter)
      end
    end
  end
end
