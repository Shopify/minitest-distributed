# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    class PendingExecution < T::Struct
      extend T::Sig

      const :worker_id, String
      const :entry_id, String
      const :elapsed_time_ms, Integer
      const :attempt, Integer

      sig { returns(String) }
      def attempt_id
        "#{entry_id}/#{attempt}"
      end

      sig { params(xpending_result: T::Hash[String, T.untyped]).returns(T.attached_class) }
      def self.from_xpending(xpending_result)
        new(
          worker_id: xpending_result.fetch("consumer"),
          entry_id: xpending_result.fetch("entry_id"),
          elapsed_time_ms: xpending_result.fetch("elapsed"),
          attempt: xpending_result.fetch("count"),
        )
      end
    end

    # This module defines some helper methods to deal with Minitest::Runnable
    module DefinedRunnable
      extend T::Sig

      sig { params(name: String).returns(T.class_of(Minitest::Runnable)) }
      def self.find_class(name)
        name.split("::")
          .reduce(Object) { |ns, const| ns.const_get(const) } # rubocop:disable Sorbet/ConstantsFromStrings
      end

      sig { params(runnable: Minitest::Runnable).returns(String) }
      def self.identifier(runnable)
        "#{T.must(runnable.class.name)}##{runnable.name}"
      end

      sig { params(identifier: String).returns(Minitest::Runnable) }
      def self.from_identifier(identifier)
        class_name, method_name = identifier.split("#", 2)
        find_class(T.must(class_name)).new(T.must(method_name))
      end
    end

    class EnqueuedRunnable < T::Struct
      class Result < T::Struct
        class Commit
          extend T::Sig

          sig { params(block: T.proc.returns(T::Boolean)).void }
          def initialize(&block)
            @block = block
          end

          sig { returns(T::Boolean) }
          def success?
            @success ||= T.let(@block.call, T.nilable(T::Boolean))
          end

          sig { returns(T::Boolean) }
          def failure?
            !success?
          end

          sig { returns(Commit) }
          def self.success
            @success ||= T.let(new { true }, T.nilable(Commit))
          end

          sig { returns(Commit) }
          def self.failure
            @failure ||= T.let(new { false }, T.nilable(Commit))
          end
        end

        extend T::Sig

        const :enqueued_runnable, EnqueuedRunnable
        const :initial_result, Minitest::Result
        const :commit, Commit

        sig { returns(String) }
        def entry_id
          enqueued_runnable.entry_id
        end

        sig { returns(T::Boolean) }
        def final?
          !requeue?
        end

        sig { returns(T::Boolean) }
        def requeue?
          ResultType.of(initial_result) == ResultType::Requeued
        end

        sig { returns(Minitest::Result) }
        def committed_result
          @committed_result ||= T.let(
            if final? && commit.failure?
              # If a runnable result is final, but the acked failed, we will discard the result.
              Minitest::Discard.wrap(
                initial_result,
                test_timeout_seconds: enqueued_runnable.test_timeout_seconds,
              )
            else
              initial_result
            end,
            T.nilable(Minitest::Result),
          )
        end
      end

      class << self
        extend T::Sig

        sig do
          params(
            claims: T::Array[[String, T::Hash[String, String]]],
            pending_messages: T::Hash[String, PendingExecution],
            configuration: Configuration,
          ).returns(T::Array[T.attached_class])
        end
        def from_redis_stream_claim(claims, pending_messages = {}, configuration:)
          claims.map do |entry_id, runnable_method_info|
            # `attempt` will be set to the current attempt of a different worker that has timed out.
            # The attempt we are going to try will be the next one, so add one.
            attempt = pending_messages.key?(entry_id) ? pending_messages.fetch(entry_id).attempt + 1 : 1

            new(
              class_name: runnable_method_info.fetch("class_name"),
              method_name: runnable_method_info.fetch("method_name"),
              entry_id: entry_id,
              attempt: attempt,
              max_attempts: configuration.max_attempts,
              test_timeout_seconds: configuration.test_timeout_seconds,
            )
          end
        end
      end

      extend T::Sig

      const :class_name, String
      const :method_name, String
      const :entry_id, String, factory: -> { SecureRandom.uuid }, dont_store: true
      const :attempt, Integer, default: 1, dont_store: true
      const :max_attempts, Integer, dont_store: true
      const :test_timeout_seconds, Float, dont_store: true

      sig { returns(String) }
      def identifier
        "#{class_name}##{method_name}"
      end

      sig { returns(String) }
      def attempt_id
        "#{entry_id}/#{attempt}"
      end

      sig { returns(T.class_of(Minitest::Runnable)) }
      def runnable_class
        DefinedRunnable.find_class(class_name)
      end

      sig { returns(Minitest::Runnable) }
      def instantiate_runnable
        runnable_class.new(method_name)
      end

      sig { returns(T::Boolean) }
      def attempts_exhausted?
        attempt > max_attempts
      end

      sig { returns(T::Boolean) }
      def final_attempt?
        attempt == max_attempts
      end

      sig { returns(Minitest::Result) }
      def attempts_exhausted_result
        assertion = Minitest::AttemptsExhausted.new(<<~EOM.chomp)
          This test takes too long to run (> #{test_timeout_seconds}s).

          We have tried running this test #{max_attempts} on different workers, but every time the worker has not reported back a result within #{test_timeout_seconds}s.
          Try to make the test faster, or increase the test timeout.
        EOM
        assertion.set_backtrace(caller)

        runnable = instantiate_runnable
        runnable.time = 0.0
        runnable.failures = [assertion]

        Minitest::Result.from(runnable)
      end

      sig do
        params(
          initial_result: Minitest::Result,
          block: T.proc.params(arg0: Minitest::Result).returns(EnqueuedRunnable::Result::Commit),
        ).returns(EnqueuedRunnable::Result)
      end
      def commit_result(initial_result, &block)
        EnqueuedRunnable::Result.new(
          enqueued_runnable: self,
          initial_result: initial_result,
          commit: block.call(initial_result),
        )
      end

      sig { returns(Minitest::Result) }
      def run
        if attempts_exhausted?
          attempts_exhausted_result
        else
          result = Minitest.run_one_method(runnable_class, method_name)
          result_type = ResultType.of(result)
          if (result_type == ResultType::Error || result_type == ResultType::Failed) && !final_attempt?
            Minitest::Requeue.wrap(result, attempt: attempt, max_attempts: max_attempts)
          else
            result
          end
        end
      end

      sig { returns(T.self_type) }
      def next_attempt
        self.class.new(
          class_name: class_name,
          method_name: method_name,
          entry_id: entry_id,
          attempt: attempt + 1,
          max_attempts: max_attempts,
          test_timeout_seconds: test_timeout_seconds,
        )
      end
    end
  end
end
