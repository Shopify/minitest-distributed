# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    class ResultAggregate < T::Struct
      extend T::Sig

      const :max_failures, T.nilable(Integer)

      # These are maintained between different attempts for the same run ID
      prop :runs, Integer, default: 0
      prop :assertions, Integer, default: 0
      prop :passes, Integer, default: 0
      prop :failures, Integer, default: 0
      prop :errors, Integer, default: 0
      prop :skips, Integer, default: 0
      prop :requeues, Integer, default: 0
      prop :discards, Integer, default: 0

      # These are reset between different attempts for the same run ID
      prop :acks, Integer, default: 0
      prop :size, Integer, default: 0

      sig { params(runnable_result: EnqueuedRunnable::Result).void }
      def update_with_result(runnable_result)
        case (result_type = ResultType.of(runnable_result.committed_result))
        when ResultType::Passed then self.passes += 1
        when ResultType::Failed then self.failures += 1
        when ResultType::Error then self.errors += 1
        when ResultType::Skipped then self.skips += 1
        when ResultType::Discarded then self.discards += 1
        when ResultType::Requeued then self.requeues += 1
        else T.absurd(result_type)
        end

        self.acks += 1 if runnable_result.final? && runnable_result.commit.success?
        self.runs += 1
        self.assertions += runnable_result.committed_result.assertions
      end

      sig { returns(String) }
      def to_s
        str = +"#{runs} runs, #{assertions} assertions, #{passes} passes, #{failures} failures, #{errors} errors"
        str << ", #{skips} skips" if skips > 0
        str << ", #{requeues} re-queued" if requeues > 0
        str << ", #{discards} discarded" if discards > 0
        str
      end

      sig { returns(Integer) }
      def unique_runs
        runs - requeues - discards
      end

      sig { returns(Integer) }
      def reported_results
        passes + failures + errors + skips
      end

      sig { returns(T::Boolean) }
      def complete?
        acks == size
      end

      sig { returns(T::Boolean) }
      def abort?
        if (max = max_failures)
          total_failures >= max
        else
          false
        end
      end

      sig { returns(T::Boolean) }
      def valid?
        all_runs_reported? && (complete? || abort?)
      end

      sig { returns(T::Boolean) }
      def all_runs_reported?
        unique_runs == reported_results
      end

      sig { returns(Integer) }
      def total_failures
        failures + errors
      end

      sig { returns(T::Boolean) }
      def passed?
        total_failures == 0
      end
    end
  end
end
