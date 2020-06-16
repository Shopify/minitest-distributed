# typed: true
# frozen_string_literal: true

require "test_helper"

class RedisCoordinatorIntegrationTest < RedisIntegrationTest
  def test_no_tests_with_read_timeout
    Toxiproxy[/redis/].downstream(:latency, latency: 100).apply do
      runner = spawn_redis_worker(
        test_file: "no_tests.rb",
        run_id: "test_no_tests",
      ).value

      assert_worker_successful(runner)
      assert_output_includes(runner, "0 runs, 0 assertions, 0 passes, 0 failures, 0 errors")
      results = combined_results(run_id: "test_no_tests")
      assert_predicate(results, :passed?)
      assert_equal(0, results.unique_runs)
      assert_equal(0, results.passes)
      assert_equal(0, results.failures)
      assert_equal(0, results.errors)
      assert_equal(0, results.skips)
    end
  end

  def test_no_tests
    runner = spawn_redis_worker(
      test_file: "no_tests.rb",
      run_id: "test_no_tests",
    ).value

    assert_worker_successful(runner)
    assert_output_includes(runner, "0 runs, 0 assertions, 0 passes, 0 failures, 0 errors")

    results = combined_results(run_id: "test_no_tests")
    assert_predicate(results, :passed?)
    assert_equal(0, results.unique_runs)
    assert_equal(0, results.passes)
    assert_equal(0, results.failures)
    assert_equal(0, results.errors)
    assert_equal(0, results.skips)
  end

  def test_passing_tests_with_one_worker
    runner = spawn_redis_worker(
      test_file: "passing_tests.rb",
      run_id: "test_passing_tests_with_one_worker",
    ).value

    assert_worker_successful(runner)
    assert_output_includes(runner, "100 runs, 100 assertions, 100 passes, 0 failures, 0 errors")

    results = combined_results(run_id: "test_passing_tests_with_one_worker")
    assert_predicate(results, :passed?)
    assert_equal(100, results.passes)
    assert_equal(0, results.failures)
    assert_equal(0, results.errors)
    assert_equal(0, results.skips)
  end

  def test_failing_tests_with_one_worker_and_two_attempts
    runner = spawn_redis_worker(
      test_file: "failing_tests.rb",
      run_id: "test_failing_tests_with_one_worker_and_two_attempts",
      arguments: {
        "--test-timeout" => "1",
        "--test-batch-size" => "1",
        "--max-attempts" => "2",
      },
    ).value

    refute_worker_successful(runner)
    assert_output_includes(runner, "101 runs, 101 assertions, 99 passes, 1 failures, 0 errors, 1 re-queued")

    results = combined_results(run_id: "test_failing_tests_with_one_worker_and_two_attempts")
    refute_predicate(results, :passed?)
    assert_equal(100, results.unique_runs)
    assert_equal(99, results.passes)
    assert_equal(1, results.failures)
    assert_equal(0, results.errors)
    assert_equal(0, results.skips)
  end

  def test_passing_tests_with_multiple_workers
    workers = spawn_redis_workers(
      count: 3,
      test_file: "passing_tests.rb",
      run_id: "test_passing_tests_with_multiple_workers",
    ).map(&:value)

    assert_all_workers_successful(workers)

    results = combined_results(run_id: "test_passing_tests_with_multiple_workers")
    assert_predicate(results, :passed?)
    assert_equal(100, results.unique_runs)
    assert_equal(100, results.passes)
    assert_equal(0, results.failures)
    assert_equal(0, results.errors)
    assert_equal(0, results.skips)
  end

  def test_failing_tests_with_multiple_workers
    workers = spawn_redis_workers(
      count: 3,
      test_file: "failing_tests.rb",
      run_id: "test_failing_tests_with_multiple_workers",
      arguments: {
        "--test-timeout" => "1",
        "--test-batch-size" => "1",
        "--max-attempts" => "3",
      },
    ).map(&:value)

    assert_some_workers_failed(workers)

    results = combined_results(run_id: "test_failing_tests_with_multiple_workers")
    refute_predicate(results, :passed?)
    assert_equal(100, results.unique_runs)
    assert_equal(99, results.passes)
    assert_equal(1, results.failures)
    assert_equal(0, results.errors)
    assert_equal(0, results.skips)
  end

  def test_crashing_worker
    # The only worker crashes.
    # The build stats should reflect the build is not complete and not successful.

    Tempfile.open("test_crashing_worker") do |f|
      worker = spawn_redis_worker(
        test_file: "crashing_tests.rb",
        run_id: "test_crashing_worker",
        env: { "CRASH_TRACKER_FILE" => f.path },
      ).value

      assert_equal(9, worker.status.termsig, "Expected worker to have been KILLed.\n#{boxed_workers_output([worker])}")
    end

    results = combined_results(run_id: "test_crashing_worker")
    refute_predicate(results, :complete?)
    assert_predicate(results, :passed?)
  end

  def test_crashing_worker_with_multiple_workers
    # This test is set up to crash the worker (kill -9) once, but will succeed on the second attempt.
    # As a result, one test worker will not be successful, but the other ones will be OK.
    # We expect the build system to be set up for these crashed test workers to not fail the build.
    # We can check the test statistics in Redis to make sure the full test suite ran successfully.

    workers = Tempfile.open("test_crashing_worker_with_multiple_workers") do |f|
      spawn_redis_workers(
        count: 2,
        test_file: "crashing_tests.rb",
        run_id: "test_crashing_worker_with_multiple_workers",
        arguments: { "--test-batch-size" => "5", "--test-timeout" => "0.1", "--max-attempts" => "3" },
        env: { "CRASH_TRACKER_FILE" => f.path },
      ).map(&:value)
    end

    grouped_workers = workers.group_by { |worker| !!worker.status.success? }
    assert_equal(1, grouped_workers[true]&.size || 0, "Expected 1 worker to succeed\n#{boxed_workers_output(workers)}")
    assert_equal(1, grouped_workers[false]&.size || 0, "Expected 1 worker to fail\n#{boxed_workers_output(workers)}")

    crashed_worker = grouped_workers[false][0]
    successful_worker = grouped_workers[true][0]

    assert_output_includes(successful_worker, "WARNING: The following tests were reclaimed from another worker")
    assert_equal("KILL", Signal.signame(crashed_worker.status.termsig))

    results = combined_results(run_id: "test_crashing_worker_with_multiple_workers")
    assert_predicate(results, :passed?)
    assert_equal(100, results.unique_runs)
    assert_equal(100, results.passes)
    assert_equal(0, results.failures)
    assert_equal(0, results.errors)
    assert_equal(0, results.skips)
  end

  def test_test_that_is_too_slow_with_enough_workers
    # Because we have more workers than attempts, one of the workers will eventually
    # claim it after all the attempts are exhausted, and mark the test as failed.
    # The other workers will continue to run the test, and eventually mark it as successful locally.
    # However, they will not be able to acknowledge the test run with Redis, so the build will fail.

    workers = spawn_redis_workers(
      count: 4,
      test_file: "slow_test.rb",
      run_id: "test_test_that_is_too_slow_with_enough_workers",
      arguments: { "--test-batch-size" => "3", "--test-timeout" => "0.05", "--max-attempts" => "3" },
      env: { "SLEEP_TIME" => "2" },
    ).map(&:value)

    # One worker should fail.
    assert_some_workers_failed(workers)

    output = normalize_output(workers_output(workers))
    assert_includes(output, "WARNING: This worker was not able to ack all the tests it ran with the coordinator")
    assert_includes(output, "WARNING: The following tests were reclaimed from another worker:")
    assert_includes(output, "This test takes too long to run (> 0.05s)")
    assert_includes(output, <<~EOM)
      Discarded:
      SlowTest#test_too_slow [/path/to/file.rb:123]:
      This test result was discarded, because it could not be committed to the test run coordinator.
    EOM

    # Even though we have only one test, it will be attempted by 4 workers:
    # 3 real attempts that are too slow and 1 fail fast attempt that gets acknowledged.
    results = combined_results(run_id: "test_test_that_is_too_slow_with_enough_workers")
    refute_predicate(results, :passed?)
    assert_equal(100, results.acks)
    assert_equal(100, results.unique_runs)
    assert_equal(99, results.passes)
    assert_equal(1, results.failures)
    assert_equal(0, results.errors)
    assert_equal(0, results.skips)
  end

  def test_test_that_is_too_slow_with_limited_workers
    # When we have fewer workers than retry attemmpts, at some point all workers
    # will be trying to process the slow test, and there is no worker left to mark is as failed.
    # As a result, the last worker will not be interruped and will be able to complete the run.
    workers = spawn_redis_workers(
      count: 3,
      test_file: "slow_test.rb",
      run_id: "test_test_that_is_too_slow_with_limited_workers",
      arguments: { "--test-batch-size" => "3", "--test-timeout" => "0.05", "--max-attempts" => "3" },
      env: { "SLEEP_TIME" => "1" },
    ).map(&:value)

    assert_all_workers_successful(workers)
    output = workers_output(workers)
    assert_includes(output, "WARNING: The following tests were reclaimed from another worker:")

    results = combined_results(run_id: "test_test_that_is_too_slow_with_limited_workers")
    assert_predicate(results, :passed?)
    assert_equal(100, results.acks)
    assert_equal(100, results.unique_runs)
    assert_equal(100, results.passes)
    assert_equal(0, results.failures)
    assert_equal(0, results.errors)
    assert_equal(0, results.skips)
  end

  def test_flaky_test_fails_with_only_one_attempt
    workers = Tempfile.open("test_flaky_test_fails_with_only_one_attempt") do |f|
      spawn_redis_workers(
        count: 3,
        test_file: "flaky_test.rb",
        run_id: "test_flaky_test_fails_with_only_one_attempt",
        arguments: { "--max-attempts" => "1", "--no-retry-failures" => "true" },
        env: { "FLAKY_TRACKER_FILE" => f.path },
      ).map(&:value)
    end

    assert_some_workers_failed(workers)

    results = combined_results(run_id: "test_flaky_test_fails_with_only_one_attempt")

    refute_predicate(results, :passed?)
    assert_equal(99, results.passes)
    assert_equal(1, results.failures)
    assert_equal(0, results.requeues)
  end

  def test_flaky_test_succeeds_after_second_attempt_with_single_worker
    worker1 = Tempfile.open("test_flaky_test_succeeds_after_second_attempt_with_single_worker") do |f|
      spawn_redis_worker(
        test_file: "flaky_test.rb",
        run_id: "test_flaky_test_succeeds_after_second_attempt_with_single_worker",
        arguments: { "--max-attempts" => "3", "--no-retry-failures" => "true" },
        env: { "FLAKY_TRACKER_FILE" => f.path },
      ).value
    end

    assert_worker_successful(worker1)

    results = combined_results(run_id: "test_flaky_test_succeeds_after_second_attempt_with_single_worker")

    assert_predicate(results, :passed?)
    assert_equal(100, results.passes)
    assert_equal(0, results.failures)
    assert_equal(1, results.requeues)
  end

  def test_flaky_test_succeeds_after_second_attempt_with_multiple_workers
    workers = Tempfile.open("test_flaky_test_succeeds_after_second_attempt_with_multiple_workers") do |f|
      spawn_redis_workers(
        count: 3,
        test_file: "flaky_test.rb",
        run_id: "test_flaky_test_succeeds_after_second_attempt_with_multiple_workers",
        arguments: { "--max-attempts" => "3", "--no-retry-failures" => "true" },
        env: { "FLAKY_TRACKER_FILE" => f.path },
      ).map(&:value)
    end

    assert_all_workers_successful(workers)

    results = combined_results(run_id: "test_flaky_test_succeeds_after_second_attempt_with_multiple_workers")

    assert_predicate(results, :passed?)
    assert_equal(100, results.passes)
    assert_equal(0, results.failures)
    assert_equal(1, results.requeues)
  end

  def test_max_failures_with_multiple_workers
    workers = spawn_redis_workers(
      count: 3,
      test_file: "only_failures.rb",
      run_id: "test_max_failures_with_multiple_workers",
      arguments: { "--max-failures" => "10", "--no-retry-failures" => "true", "--test-batch-size" => "1" },
    ).map(&:value)

    assert_some_workers_failed(workers)
    assert_includes(workers_output(workers), "The run was cut short after reaching the limit of 10 test failures.")

    results = combined_results(run_id: "test_max_failures_with_multiple_workers", max_failures: 10)
    refute_predicate(results, :passed?)
    assert_predicate(results, :valid?)

    # Once one worker decided to abort the run, the other workers will complete their tests
    # that are in progress before they will exit, increasing the number of failures.
    assert_operator(results.failures, :>=, 10)
  end

  def test_with_progress
    # When we boot workers in our test suite, we pipe the output. As a result, STDOUT is
    # not a TTY, and by default progress reporting is disabled. This has caused issues in
    # the past. In this test, we explicitly enable progress reporting so we can exercise
    # this code even when the output will not be sent to a TTY.
    workers = spawn_redis_workers(
      count: 2,
      test_file: "passing_tests.rb",
      run_id: "test_with_progress",
      arguments: { "--progress" => "true", "--test-batch-size" => "5" },
    ).map(&:value)

    assert_all_workers_successful(workers)

    output = workers_output(workers)
    assert_includes(output, "/100] PassingTests#test_pass_0")
    assert_includes(output, "/100] PassingTests#test_pass_99")
  end
end
