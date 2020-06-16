# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    module Reporters
      class DistributedSummaryReporter < Minitest::Reporter
        extend T::Sig

        sig { params(io: IO, options: T::Hash[Symbol, T.untyped]).void }
        def initialize(io, options)
          super
          io.sync = true
          @start_time = T.let(0.0, Float)
        end

        sig { override.void }
        def start
          @start_time = Minitest.clock_time
          io.puts("Run options: #{options[:args]}\n\n")
        end

        sig { override.void }
        def report
          print_discard_warning if local_results.discards > 0

          if configuration.coordinator.aborted?
            io.puts("Cannot retry a run that was cut short during the previous attempt.")
            io.puts
          elsif combined_results.abort?
            io.puts("The run was cut short after reaching the limit of #{configuration.max_failures} test failures.")
            io.puts
          end

          formatted_duration = format("(in %0.3fs)", Minitest.clock_time - @start_time)
          if combined_results == local_results
            io.puts("Results: #{combined_results} #{formatted_duration}")
          else
            io.puts("This worker:      #{local_results} #{formatted_duration}")
            io.puts("Combined results: #{combined_results}")
          end
        end

        sig { override.returns(T::Boolean) }
        def passed?
          return false if configuration.coordinator.aborted?

          # Generally, we want the workers to fail that had at least one failed or errored
          # test. We have to trust that another worker will fail (and fail the build) if it
          # encountered a failed test. We trust that the other worker will do this correctly,
          # but we do verify that the statistics for the complete run are valid,
          # to have some protection against unknown edge cases and bugs.
          local_results.passed? && combined_results.valid?
        end

        protected

        sig { void }
        def print_discard_warning
          io.puts(<<~WARNING)
            WARNING: This worker was not able to ack all the tests it ran with the coordinator,
            and had to discard the results of those tests. This means that some of your tests may
            take too long to run. Make sure that all your tests complete well within #{configuration.test_timeout_seconds}s.

          WARNING
        end

        sig { returns(ResultAggregate) }
        def local_results
          @local_results ||= T.let(configuration.coordinator.local_results, T.nilable(ResultAggregate))
        end

        sig { returns(ResultAggregate) }
        def combined_results
          @combined_results ||= T.let(configuration.coordinator.combined_results, T.nilable(ResultAggregate))
        end

        sig { returns(Configuration) }
        def configuration
          T.let(options[:distributed], Configuration)
        end
      end
    end
  end
end
