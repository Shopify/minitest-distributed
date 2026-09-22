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
          print_discard_warning if local_results.discards > 0 && !current_attempt_truncated?

          if registration_rejected?
            print_local_results("Combined results are unavailable because coordinator registration was rejected.")
            return
          elsif truncation_state_invalid?
            print_local_results("Combined results are unavailable because the retained truncation state is incomplete.")
            return
          elsif coordinator_stalled?
            print_local_results("Combined results are unavailable because the Redis coordinator state is invalid.")
            return
          elsif retry_refused_due_to_truncation?
            io.puts("Cannot retry a run that was cut short during the previous attempt.")
            print_local_results("Combined results were not read for this rejected retry.")
            return
          elsif current_attempt_truncated?
            io.puts("The run was cut short after another worker reached the max-failures limit.")
            print_local_results("Combined results were not read after truncation.")
            return
          elsif configuration.coordinator.aborted?
            print_local_results("Combined results are unavailable because the coordinator aborted this worker.")
            return
          end

          persisted_truncation = configuration.coordinator.persisted_truncation?
          @combined_results = nil
          unless configuration.coordinator.valid_combined_results?
            if persisted_truncation
              io.puts("The run was cut short after reaching the limit of #{configuration.max_failures} test failures.")
            end
            print_local_results("Combined results are unavailable because terminal coordinator state is invalid.")
            return
          end

          if persisted_truncation
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
          local_results.passed? && configuration.coordinator.valid_combined_results?
        end

        protected

        sig { params(message: String).void }
        def print_local_results(message)
          formatted_duration = format("(in %0.3fs)", Minitest.clock_time - @start_time)
          io.puts("This worker: #{local_results} #{formatted_duration}")
          io.puts(message)
        end

        sig { void }
        def print_discard_warning
          io.puts(<<~WARNING)
            WARNING: This worker was not able to ack all the tests it ran with the coordinator,
            and had to discard the results of those tests. This means that some of your tests may
            take too long to run. Make sure that all your tests complete well within #{configuration.test_timeout_seconds}s.

          WARNING
        end

        sig { returns(T::Boolean) }
        def registration_rejected?
          coordinator = T.unsafe(configuration.coordinator)
          coordinator.respond_to?(:registration_rejected?) && !!coordinator.registration_rejected?
        end

        sig { returns(T::Boolean) }
        def truncation_state_invalid?
          coordinator = T.unsafe(configuration.coordinator)
          coordinator.respond_to?(:truncation_state_invalid?) && !!coordinator.truncation_state_invalid?
        end

        sig { returns(T::Boolean) }
        def retry_refused_due_to_truncation?
          coordinator = T.unsafe(configuration.coordinator)
          coordinator.respond_to?(:retry_refused_due_to_truncation?) && !!coordinator.retry_refused_due_to_truncation?
        end

        sig { returns(T::Boolean) }
        def current_attempt_truncated?
          coordinator = T.unsafe(configuration.coordinator)
          coordinator.respond_to?(:current_attempt_truncated?) && !!coordinator.current_attempt_truncated?
        end

        sig { returns(T::Boolean) }
        def coordinator_stalled?
          coordinator = T.unsafe(configuration.coordinator)
          coordinator.respond_to?(:stalled?) && !!coordinator.stalled?
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
