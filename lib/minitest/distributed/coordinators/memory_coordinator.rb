# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    module Coordinators
      class MemoryCoordinator
        extend T::Sig
        include CoordinatorInterface

        sig { returns(Configuration) }
        attr_reader :configuration

        sig { returns(Queue) }
        attr_reader :queue

        sig { override.returns(ResultAggregate) }
        attr_reader :local_results

        alias_method :combined_results, :local_results

        sig { params(configuration: Configuration).void }
        def initialize(configuration:)
          @configuration = configuration

          @leader = T.let(Mutex.new, Mutex)
          @queue = T.let(Queue.new, Queue)
          @local_results = T.let(ResultAggregate.new(max_failures: configuration.max_failures), ResultAggregate)
          @aborted = T.let(false, T::Boolean)
        end

        sig { override.params(reporter: Minitest::CompositeReporter, options: T::Hash[Symbol, T.untyped]).void }
        def register_reporters(reporter:, options:)
          # No need for any additional reporters
        end

        sig { override.returns(T::Boolean) }
        def aborted?
          @aborted
        end

        sig { override.params(test_selector: TestSelector).void }
        def produce(test_selector:)
          if @leader.try_lock
            tests = test_selector.tests
            @local_results.size = tests.size
            if tests.empty?
              queue.close
            else
              tests.each do |runnable|
                queue << EnqueuedRunnable.new(
                  class_name: T.must(runnable.class.name),
                  method_name: runnable.name,
                  test_timeout_seconds: configuration.test_timeout_seconds,
                  max_attempts: configuration.max_attempts,
                )
              end
            end
          end
        end

        sig { override.params(reporter: AbstractReporter).void }
        def consume(reporter:)
          until queue.closed?
            enqueued_runnable = T.let(queue.pop, EnqueuedRunnable)

            reporter.prerecord(enqueued_runnable.runnable_class, enqueued_runnable.method_name)

            initial_result = enqueued_runnable.run
            enqueued_result = enqueued_runnable.commit_result(initial_result) do |result_to_commit|
              if ResultType.of(result_to_commit) == ResultType::Requeued
                queue << enqueued_runnable.next_attempt
              end
              EnqueuedRunnable::Result::Commit.success
            end

            reporter.record(enqueued_result.committed_result)
            local_results.update_with_result(enqueued_result)

            # We abort a run if we reach the maximum number of failures
            queue.close if combined_results.abort?
            queue.close if combined_results.complete?
          end
        end
      end
    end
  end
end
