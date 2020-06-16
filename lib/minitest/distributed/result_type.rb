# typed: strict
# frozen_string_literal: true

module Minitest
  class Discard < Minitest::Skip
    extend T::Sig

    sig { returns(Minitest::Result) }
    attr_reader :original_result

    sig { params(message: String, original_result: Minitest::Result).void }
    def initialize(message, original_result:)
      @original_result = original_result
      super(message)
    end

    sig { override.returns(String) }
    def result_label
      "Discarded"
    end

    sig { params(result: Minitest::Result, test_timeout_seconds: Float).returns(Minitest::Result) }
    def self.wrap(result, test_timeout_seconds:)
      message = +"This test result was discarded, because it could not be committed to the test run coordinator."
      if result.time > test_timeout_seconds
        message << format(
          "\n\nThe test took %0.3fs to run, longer than the test timeout which is configured to be %0.1fs.\n" \
            "Another worker likely claimed ownership of this test, and will commit the result instead.\n" \
            "For best results, make sure that all your tests finish within %0.1fs.",
          result.time,
          test_timeout_seconds,
          test_timeout_seconds,
        )
      end

      discard_assertion = Minitest::Discard.new(message, original_result: result)
      discard_assertion.set_backtrace(caller)
      discarded_result = result.dup
      discarded_result.failures = [discard_assertion]
      discarded_result
    end
  end

  class Requeue < Minitest::Skip
    extend T::Sig

    sig { params(message: String, original_result: Minitest::Result).void }
    def initialize(message, original_result:)
      @original_result = original_result
      super(message)
    end

    sig { override.returns(String) }
    def result_label
      "Requeued"
    end

    sig { params(result: Minitest::Result, attempt: Integer, max_attempts: Integer).returns(Minitest::Result) }
    def self.wrap(result, attempt:, max_attempts:)
      failure = T.must(result.failure)

      message = "#{failure.message}\n\nThe test will be retried (attempt #{attempt} of #{max_attempts})"
      requeue_assertion = Minitest::Requeue.new(message, original_result: result)
      requeue_assertion.set_backtrace(failure.backtrace)

      requeued_result = result.dup
      requeued_result.failures = [requeue_assertion]
      requeued_result
    end
  end

  class AttemptsExhausted < Minitest::Assertion
  end

  module Distributed
    class ResultType < T::Enum
      extend T::Sig

      enums do
        Passed = new
        Failed = new
        Error = new
        Skipped = new
        Discarded = new
        Requeued = new
      end

      sig { params(result: Minitest::Result).returns(ResultType) }
      def self.of(result)
        if result.passed?
          Passed
        elsif result.failure.is_a?(Minitest::Requeue)
          Requeued
        elsif result.failure.is_a?(Minitest::Discard)
          Discarded
        elsif result.skipped?
          Skipped
        elsif result.error?
          Error
        else
          Failed
        end
      end
    end
  end
end
