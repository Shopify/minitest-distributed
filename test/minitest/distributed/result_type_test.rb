# typed: true
# frozen_string_literal: true

require "test_helper"

module Minitest
  module Distributed
    class ResultTypeTest < Minitest::Test
      def test_result_type_of_passed
        passed = Minitest::Result.new("foo")
        passed.failures = []

        assert_predicate(passed, :passed?)
        refute_predicate(passed, :skipped?)
        refute_predicate(passed, :error?)

        assert_equal(ResultType::Passed, ResultType.of(passed))
      end

      def test_result_type_of_attempts_exhausted
        attempts_exhausted = Minitest::Result.new("foo")
        attempts_exhausted.failures = [Minitest::AttemptsExhausted.new("error")]

        refute_predicate(attempts_exhausted, :passed?)
        refute_predicate(attempts_exhausted, :skipped?)
        refute_predicate(attempts_exhausted, :error?)

        assert_equal(ResultType::Failed, ResultType.of(attempts_exhausted))
      end

      def test_attempts_exhausted_to_s
        assertion = Minitest::AttemptsExhausted.new("Final attempt exhausted")
        assertion.set_backtrace(caller)

        attempts_exhausted = Minitest::Result.new("foo")
        attempts_exhausted.klass = "MyTest"
        attempts_exhausted.failures = [assertion]

        failure_output = normalize_output(attempts_exhausted.to_s)
        assert_equal(<<~EOM, failure_output)
          Failure:
          MyTest#foo [/path/to/my_test.rb:123]:
          Final attempt exhausted
        EOM
      end

      def test_result_type_of_discarded_pass
        pass = Minitest::Result.new("foo")
        pass.klass = "MyTest"
        pass.source_location = ["my_test.rb", 123]
        pass.time = 0.0

        discarded_pass = Minitest::Discard.wrap(pass, test_timeout_seconds: 0.0)

        assert_equal("foo", discarded_pass.name)
        assert_equal("MyTest", discarded_pass.class_name)
        assert_equal(["my_test.rb", 123], discarded_pass.source_location)

        assert_predicate(discarded_pass, :skipped?)
        refute_predicate(discarded_pass, :passed?)
        refute_predicate(discarded_pass, :error?)

        assert_equal(ResultType::Discarded, ResultType.of(discarded_pass))
      end

      def test_result_type_of_discarded_error
        error = Minitest::Result.new("foo")
        error.failures = [Minitest::UnexpectedError.new(RuntimeError.new)]
        error.time = 0.0
        discarded_error = Minitest::Discard.wrap(error, test_timeout_seconds: 0.0)

        assert_predicate(discarded_error, :skipped?)
        refute_predicate(discarded_error, :passed?)
        refute_predicate(discarded_error, :error?)

        assert_equal(ResultType::Discarded, ResultType.of(discarded_error))
      end

      def test_discarded_error_to_s
        error = Minitest::Result.new("foo")
        error.klass = "MyTest"
        error.failures = [Minitest::UnexpectedError.new(RuntimeError.new)]
        error.time = 0.9
        discarded_error = Minitest::Discard.wrap(error, test_timeout_seconds: 1.0)

        failure_output = normalize_output(discarded_error.to_s)
        assert_equal(<<~EOM, failure_output)
          Discarded:
          MyTest#foo [/path/to/my_test.rb:123]:
          This test result was discarded, because it could not be committed to the test run coordinator.
        EOM
      end

      def test_discarded_pass_to_s_after_timeout
        pass = Minitest::Result.new("foo")
        pass.klass = "MyTest"
        pass.time = 2.0
        discarded_pass = Minitest::Discard.wrap(pass, test_timeout_seconds: 1.0)

        failure_output = normalize_output(discarded_pass.to_s)
        assert_equal(<<~EOM, failure_output)
          Discarded:
          MyTest#foo [/path/to/my_test.rb:123]:
          This test result was discarded, because it could not be committed to the test run coordinator.

          The test took 2.000s to run, longer than the test timeout which is configured to be 1.0s.
          Another worker likely claimed ownership of this test, and will commit the result instead.
          For best results, make sure that all your tests finish within 1.0s.
        EOM
      end

      def test_result_type_of_requeued_failure
        failure = Minitest::Result.new("foo")
        failure.failures = [Minitest::Assertion.new("this test failed")]

        requeued_failure = Minitest::Requeue.wrap(failure, attempt: 1, max_attempts: 3)

        refute_predicate(requeued_failure, :passed?)
        assert_predicate(requeued_failure, :skipped?)
        refute_predicate(requeued_failure, :error?)

        assert_equal(ResultType::Requeued, ResultType.of(requeued_failure))
      end

      def test_requeued_failure_to_s
        assertion = Minitest::Assertion.new("this test failed")
        assertion.set_backtrace(caller)

        failure = Minitest::Result.new("foo")
        failure.failures = [assertion]
        failure.klass = "MyTest"
        failure.source_location = ["test/path/to/my_test.rb", 123]

        requeued_failure = Minitest::Requeue.wrap(failure, attempt: 2, max_attempts: 3)
        failure_output = normalize_output(requeued_failure.to_s)
        assert_equal(<<~EOM, failure_output)
          Requeued:
          MyTest#foo [/path/to/my_test.rb:123]:
          this test failed

          The test will be retried (attempt 2 of 3)
        EOM
      end

      def test_result_type_of_skip_and_error
        skip_and_error = Minitest::Result.new("foo")
        skip_and_error.failures = [
          Minitest::Skip.new("skipped"),
          Minitest::UnexpectedError.new(RuntimeError.new),
        ]

        refute_predicate(skip_and_error, :passed?)
        assert_predicate(skip_and_error, :skipped?)
        assert_predicate(skip_and_error, :error?)

        assert_equal(ResultType::Skipped, ResultType.of(skip_and_error))
      end

      def test_result_type_of_error_and_skip
        error_and_skip = Minitest::Result.new("foo")
        error_and_skip.failures = [
          Minitest::UnexpectedError.new(RuntimeError.new),
          Minitest::Skip.new("skipped"),
        ]

        refute_predicate(error_and_skip, :passed?)
        refute_predicate(error_and_skip, :skipped?)
        assert_predicate(error_and_skip, :error?)

        assert_equal(ResultType::Error, ResultType.of(error_and_skip))
      end

      def test_result_type_of_failure_and_error
        error_and_skip = Minitest::Result.new("foo")
        error_and_skip.failures = [
          Minitest::Assertion.new("failed"),
          Minitest::UnexpectedError.new(RuntimeError.new),
        ]

        refute_predicate(error_and_skip, :passed?)
        refute_predicate(error_and_skip, :skipped?)
        assert_predicate(error_and_skip, :error?)

        assert_equal(ResultType::Error, ResultType.of(error_and_skip))
      end

      def test_result_type_of_failures
        error_and_skip = Minitest::Result.new("foo")
        error_and_skip.failures = [
          Minitest::Assertion.new("failed once"),
          Minitest::Assertion.new("failed twice"),
        ]

        refute_predicate(error_and_skip, :passed?)
        refute_predicate(error_and_skip, :skipped?)
        refute_predicate(error_and_skip, :error?)

        assert_equal(ResultType::Failed, ResultType.of(error_and_skip))
      end

      private

      def normalize_output(output)
        output.gsub(%r{\[(?:/[\w+\-\.]+)+\:\d+\]}i, "[/path/to/my_test.rb:123]")
      end
    end
  end
end
