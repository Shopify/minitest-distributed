# typed: true
# frozen_string_literal: true

require "test_helper"
require "digest/sha1"

class RedisRetryModeIntegrationTest < RedisIntegrationTest
  def test_retry_passing_build_is_noop
    worker1 = spawn_redis_worker(
      test_file: "passing_tests.rb",
      run_id: "test_retry_passing_build_is_noop",
    ).value

    assert_worker_successful(worker1)
    results = combined_results(run_id: "test_retry_passing_build_is_noop")
    assert_predicate(results, :passed?)
    assert_equal(100, results.size)
    assert_equal(100, results.passes)

    # The second attempt should not run any tests becuase they were all successful
    # on the initial attempt. Size of the rtery run should be 0, other statistics
    # should be unaffected by the second attempt.

    worker2 = spawn_redis_worker(
      test_file: "passing_tests.rb",
      run_id: "test_retry_passing_build_is_noop",
    ).value

    assert_worker_successful(worker2)
    results = combined_results(run_id: "test_retry_passing_build_is_noop")
    assert_predicate(results, :passed?)
    assert_equal(0, results.size)
    assert_equal(0, results.requeues)
    assert_equal(100, results.passes)
  end

  def test_retry_with_missing_statistic_runs_the_full_suite
    run_id = "test_retry_with_missing_statistic_runs_the_full_suite"
    worker1 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker1)

    @redis.del("minitest/v3/#{run_id}/assertions")

    worker2 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")

    results = combined_results(run_id: run_id)
    assert_equal(100, results.size)
    assert_equal(100, results.runs)
    assert_equal(100, results.assertions)
    assert_equal(100, results.passes)
  end

  def test_retry_with_invalid_counter_runs_the_full_suite
    run_id = "test_retry_with_invalid_counter_runs_the_full_suite"
    worker1 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker1)

    @redis.set("minitest/v3/#{run_id}/acks", "not-a-number")

    worker2 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")

    results = combined_results(run_id: run_id)
    assert_equal(100, results.size)
    assert_equal(100, results.acks)
    assert_equal(100, results.passes)
  end

  def test_retry_with_missing_failure_list_runs_the_full_suite
    run_id = "test_retry_with_missing_failure_list_runs_the_full_suite"
    worker1 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker1)

    @redis.del("minitest/v3/#{run_id}/failed_list")

    worker2 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")

    results = combined_results(run_id: run_id)
    assert_equal(100, results.size)
    assert_equal(100, results.runs)
    assert_equal(99, results.passes)
    assert_equal(1, results.failures)
    assert_equal(0, results.requeues)
  end

  def test_retry_with_invalid_failure_list_type_runs_the_full_suite
    run_id = "test_retry_with_invalid_failure_list_type_runs_the_full_suite"
    worker1 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker1)

    @redis.del("minitest/v3/#{run_id}/failed_list")
    @redis.set("minitest/v3/#{run_id}/failed_list", "not-a-list")

    worker2 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")

    results = combined_results(run_id: run_id)
    assert_equal(100, results.size)
    assert_equal(100, results.runs)
    assert_equal(1, results.failures)
    assert_equal(0, results.requeues)
  end

  def test_retry_with_redis_numeric_syntax_runs_the_full_suite
    run_id = "test_retry_with_redis_numeric_syntax_runs_the_full_suite"
    worker1 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker1)

    @redis.set("minitest/v3/#{run_id}/assertions", "1e2")

    worker2 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")
    assert_equal(100, combined_results(run_id: run_id).assertions)
  end

  def test_retry_with_invalid_retained_state_types_runs_the_full_suite
    ["retry_set", "skipped_list"].each do |key_name|
      run_id = "test_retry_with_invalid_#{key_name}_type_runs_the_full_suite"
      worker1 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
      refute_worker_successful(worker1)

      @redis.del("minitest/v3/#{run_id}/#{key_name}")
      @redis.set("minitest/v3/#{run_id}/#{key_name}", "wrong-type")

      worker2 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
      refute_worker_successful(worker2)
      assert_output_includes(worker2, "Running the full test suite instead of a selective retry")
      assert_equal(100, combined_results(run_id: run_id).size)
    end
  end

  def test_retry_with_invalid_generation_type_runs_the_full_suite
    run_id = "test_retry_with_invalid_generation_type_runs_the_full_suite"
    worker1 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker1)

    @redis.del("minitest/v3/#{run_id}/attempt_generation")
    @redis.lpush("minitest/v3/#{run_id}/attempt_generation", "wrong-type")

    worker2 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")
    assert_equal(100, combined_results(run_id: run_id).size)
  end

  def test_retry_generation_clears_previous_fast_retry_markers
    run_id = "test_retry_generation_clears_previous_fast_retry_markers"
    worker1 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker1)

    retry_set_key = "minitest/v3/#{run_id}/retry_set"
    @redis.sadd(retry_set_key, "old-stream-entry")

    worker2 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker2)
    refute(@redis.sismember(retry_set_key, "old-stream-entry"))
  end

  def test_retry_with_invalid_stream_type_runs_the_full_suite
    run_id = "test_retry_with_invalid_stream_type_runs_the_full_suite"
    worker1 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker1)

    @redis.set("minitest/v3/#{run_id}/queue", "wrong-type")

    worker2 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")
    assert_equal(100, combined_results(run_id: run_id).size)
  end

  def test_retry_with_invalid_truncated_marker_runs_the_full_suite
    run_id = "test_retry_with_invalid_truncated_marker_runs_the_full_suite"
    worker1 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker1)

    generation = String(@redis.get("minitest/v3/#{run_id}/attempt_generation"))
    stream = "minitest/v3/#{run_id}/queue"
    @redis.xgroup(:create, stream, "minitest-distributed-v3-#{generation}", "0", mkstream: true)
    @redis.set("minitest/v3/#{run_id}/truncated", "0")

    worker2 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")
    refute_includes(worker2.stdout, "Cannot retry a run that was cut short")
  end

  def test_retry_with_negative_completion_counters_runs_the_full_suite
    run_id = "test_retry_with_negative_completion_counters_runs_the_full_suite"
    worker1 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker1)

    @redis.set("minitest/v3/#{run_id}/acks", "-1")
    @redis.set("minitest/v3/#{run_id}/size", "-1")

    worker2 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")
    assert_equal(100, combined_results(run_id: run_id).acks)
  end

  def test_retry_with_inconsistent_aggregate_runs_the_full_suite
    run_id = "test_retry_with_inconsistent_aggregate_runs_the_full_suite"
    worker1 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker1)

    @redis.set("minitest/v3/#{run_id}/runs", "99")

    worker2 = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")
    assert_equal(100, combined_results(run_id: run_id).runs)
  end

  def test_invalid_retained_identifier_falls_back_to_a_clean_full_rerun
    run_id = "test_invalid_retained_identifier_falls_back_to_a_clean_full_rerun"
    worker1 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker1)

    failed_list = "minitest/v3/#{run_id}/failed_list"
    identifier = "FailingTests#test_removed"
    @redis.del(failed_list)
    @redis.rpush(failed_list, identifier)
    digest_payload = ["failures", "1", identifier.length.to_s, identifier, "errors", "0"].join("\0")
    @redis.set("minitest/v3/#{run_id}/retry_snapshot_digest", Digest::SHA1.hexdigest(digest_payload))

    worker2 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker2)
    assert_output_includes(worker2, "retained an invalid retry identifier")
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")

    results = combined_results(run_id: run_id)
    assert_equal(100, results.size)
    assert_equal(100, results.runs)
    assert_equal(0, results.requeues)
    assert_equal(1, results.failures)
  end

  def test_substituted_valid_retry_identifier_falls_back_to_a_clean_full_rerun
    run_id = "test_substituted_valid_retry_identifier_falls_back_to_a_clean_full_rerun"
    worker1 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker1)

    failed_list = "minitest/v3/#{run_id}/failed_list"
    @redis.del(failed_list)
    @redis.rpush(failed_list, "FailingTests#test_pass_0")

    worker2 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")

    results = combined_results(run_id: run_id)
    assert_equal(100, results.size)
    assert_equal(100, results.runs)
    assert_equal(0, results.requeues)
    assert_equal(1, results.failures)
  end

  def test_retry_failed_build_with_consistently_failing_test
    worker1 = spawn_redis_worker(
      test_file: "failing_tests.rb",
      run_id: "test_retry_failed_build_with_consistently_failing_test",
    ).value

    refute_worker_successful(worker1)

    results = combined_results(run_id: "test_retry_failed_build_with_consistently_failing_test")
    refute_predicate(results, :passed?)
    assert_equal(100, results.size)
    assert_equal(99, results.passes)
    assert_equal(1, results.failures)
    assert_equal(0, results.requeues)

    # The second attempt should only run the test that failed. The run should
    # still fail because the second attempt to run the failed tests will also fail.
    # STatistics should be unaffected.

    worker2 = spawn_redis_worker(
      test_file: "failing_tests.rb",
      run_id: "test_retry_failed_build_with_consistently_failing_test",
      arguments: { "--retry-failures" => "true" },
    ).value

    refute_worker_successful(worker2)

    results = combined_results(run_id: "test_retry_failed_build_with_consistently_failing_test")
    refute_predicate(results, :passed?)
    assert_equal(1, results.size)
    assert_equal(99, results.passes)
    assert_equal(1, results.failures)
    assert_equal(1, results.requeues)
  end

  def test_retry_failed_build_with_retry_mode_disabled
    worker1 = spawn_redis_worker(
      test_file: "failing_tests.rb",
      run_id: "test_retry_failed_build_with_retry_mode_disabled",
    ).value

    refute_worker_successful(worker1)

    results = combined_results(run_id: "test_retry_failed_build_with_retry_mode_disabled")
    refute_predicate(results, :passed?)
    assert_equal(100, results.size)
    assert_equal(99, results.passes)
    assert_equal(1, results.failures)
    assert_equal(0, results.requeues)

    # With retry mode disabled, the second attempt will simply do nothing, because the run was already complete.

    worker2 = spawn_redis_worker(
      test_file: "failing_tests.rb",
      run_id: "test_retry_failed_build_with_retry_mode_disabled",
      arguments: { "--no-retry-failures" => "true" },
    ).value

    assert_worker_successful(worker2)

    results = combined_results(run_id: "test_retry_failed_build_with_retry_mode_disabled")
    refute_predicate(results, :passed?)
    assert_equal(0, results.size)
    assert_equal(99, results.passes)
    assert_equal(1, results.failures)
    assert_equal(0, results.requeues)

    worker3 = spawn_redis_worker(
      test_file: "failing_tests.rb",
      run_id: "test_retry_failed_build_with_retry_mode_disabled",
      arguments: { "--no-retry-failures" => "true" },
    ).value
    assert_worker_successful(worker3)
    refute_includes(worker3.stdout, "Running the full test suite")
  end

  def test_retry_failed_build_with_intermittently_failing_test
    Tempfile.open("test_intermittently_failing_test_succeeds_after_second_attempt_with_multiple_workers") do |f|
      worker1 = spawn_redis_worker(
        test_file: "flaky_test.rb",
        run_id: "test_retry_failed_build_with_intermittently_failing_test",
        arguments: { "--max-attempts" => "1" },
        env: { "FLAKY_TRACKER_FILE" => f.path },
      ).value

      refute_worker_successful(worker1)

      results = combined_results(run_id: "test_retry_failed_build_with_intermittently_failing_test")
      refute_predicate(results, :passed?)
      assert_equal(100, results.size)
      assert_equal(99, results.passes)
      assert_equal(1, results.failures)

      # The second attempt should only retry the failed flaky tests, which will now succeed.
      # The number of passes increases to 100, the number of failures goes down to 0.

      worker2 = spawn_redis_worker(
        test_file: "flaky_test.rb",
        run_id: "test_retry_failed_build_with_intermittently_failing_test",
        arguments: { "--max-attempts" => "1", "--retry-failures" => "true" },
        env: { "FLAKY_TRACKER_FILE" => f.path },
      ).value

      assert_worker_successful(worker2)

      results = combined_results(run_id: "test_retry_failed_build_with_intermittently_failing_test")
      assert_predicate(results, :passed?)
      assert_equal(1, results.size)
      assert_equal(100, results.passes)
      assert_equal(0, results.failures)
      assert_equal(1, results.requeues)
    end
  end

  def test_retry_failed_build_with_multiple_workers
    workers = spawn_redis_workers(
      count: 3,
      test_file: "many_failing_tests.rb",
      run_id: "test_retry_failed_build_with_multiple_workers",
      arguments: { "--max-attempts" => "3", "--no-retry-failures" => "true" },
    ).map(&:value)

    assert_some_workers_failed(workers)

    results = combined_results(run_id: "test_retry_failed_build_with_multiple_workers")
    refute_predicate(results, :passed?)
    assert_equal(50, results.passes)
    assert_equal(25, results.failures)
    assert_equal(25, results.errors)
    assert_equal(100, results.unique_runs)

    # We have 50 * 2 = 100 tests being requeued. (3 attempts = 2 requeues)
    assert_equal(100, results.requeues)

    # The retry run will re-attempt the 25 failures and 25 errors, but the results
    # will be exactly the same. This integration test mostly guards against race conditions
    # when running multiple workers simulatanously.

    workers = spawn_redis_workers(
      count: 3,
      test_file: "many_failing_tests.rb",
      run_id: "test_retry_failed_build_with_multiple_workers",
      arguments: { "--max-attempts" => "3", "--retry-failures" => "true" },
    ).map(&:value)

    assert_some_workers_failed(workers)

    results = combined_results(run_id: "test_retry_failed_build_with_multiple_workers")
    refute_predicate(results, :passed?)
    assert_equal(50, results.passes)
    assert_equal(25, results.failures)
    assert_equal(25, results.errors)
    assert_equal(100, results.unique_runs)

    # We don't reset the number of requeues between attempts.
    # So we end up 50*2 + 50 when starting the retry run +
    # 50*2 for the second attempt = 250 requeues in total.
    assert_equal(250, results.requeues)
  end

  def test_concurrent_workers_join_truncated_retry_generation
    run_id = "test_concurrent_workers_join_truncated_retry_generation"
    worker1 = spawn_redis_worker(
      test_file: "only_failures.rb",
      run_id: run_id,
      arguments: { "--no-retry-failures" => "true", "--max-failures" => "10" },
    ).value
    refute_worker_successful(worker1)

    workers = spawn_redis_workers(
      count: 3,
      test_file: "only_failures.rb",
      run_id: run_id,
      arguments: { "--retry-failures" => "true", "--max-failures" => "10" },
    ).map(&:value)

    assert_some_workers_failed(workers)
    refute_includes(workers_output(workers), "STALEATTEMPT")
    refute_includes(workers_output(workers), "COORDINATORSTREAM")
  end

  def test_new_max_failures_does_not_reclassify_a_completed_run_as_truncated
    run_id = "test_new_max_failures_does_not_reclassify_a_completed_run_as_truncated"
    worker1 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker1)

    worker2 = spawn_redis_worker(
      test_file: "failing_tests.rb",
      run_id: run_id,
      arguments: { "--no-retry-failures" => "true", "--max-failures" => "1" },
    ).value

    assert_worker_successful(worker2)
    refute(@redis.exists?("minitest/v3/#{run_id}/truncated"))
  end

  def test_markerless_incomplete_max_failure_snapshot_runs_the_full_suite
    run_id = "test_markerless_incomplete_max_failure_snapshot_runs_the_full_suite"
    worker1 = spawn_redis_worker(
      test_file: "only_failures.rb",
      run_id: run_id,
      arguments: { "--no-retry-failures" => "true", "--max-failures" => "10" },
    ).value
    refute_worker_successful(worker1)
    @redis.del("minitest/v3/#{run_id}/truncated")

    worker2 = spawn_redis_worker(test_file: "only_failures.rb", run_id: run_id).value
    refute_worker_successful(worker2)
    assert_output_includes(worker2, "Running the full test suite instead of a selective retry")
    refute_includes(worker2.stdout, "Cannot retry a run that was cut short")
    assert_equal(100, combined_results(run_id: run_id).size)
  end

  def test_retry_attempt_on_run_that_was_cut_short
    # When we the initial attempt is cut short because we reach the maximum number
    # of failures, we have to decide what to do when a retry is attempted.
    worker1 = spawn_redis_worker(
      test_file: "only_failures.rb",
      run_id: "test_retry_attempt_on_run_that_was_cut_short",
      arguments: { "--no-retry-failures" => "true", "--max-failures" => "10" },
    ).value

    refute_worker_successful(worker1)
    assert_includes(worker1.stdout, "The run was cut short after reaching the limit of 10 test failures.")

    initial_results = combined_results(run_id: "test_retry_attempt_on_run_that_was_cut_short")
    refute_predicate(initial_results, :passed?)
    assert_equal(100, initial_results.size)
    assert_equal(0, initial_results.passes)
    assert_equal(10, initial_results.failures)
    assert_equal(0, initial_results.requeues)

    # We now attenmpt to retry the 10 failures, even though all 100 tests
    # would have failed if we would not have specified max-attempts.
    worker2 = spawn_redis_worker(
      test_file: "only_failures.rb",
      run_id: "test_retry_attempt_on_run_that_was_cut_short",
      arguments: { "--retry-failures" => "true", "--max-failures" => "10" },
    ).value

    # In our current implementation, we simply immediately fail the attempt without
    # running any tests, because we don't know what tests were previosuly not run.
    refute_worker_successful(worker2)
    assert_includes(worker2.stdout, "Cannot retry a run that was cut short during the previous attempt.")

    # The combined results of the run are maintained, but the size of the second attempt was 0.
    new_results = combined_results(run_id: "test_retry_attempt_on_run_that_was_cut_short")
    refute_predicate(new_results, :passed?)
    assert_equal(0, new_results.size)
    assert_equal(0, new_results.passes)
    assert_equal(10, new_results.failures)
    assert_equal(0, new_results.requeues)

    # Removing the limit on a later invocation must not make the truncated
    # attempt eligible for a selective retry: many tests were never run.
    worker3 = spawn_redis_worker(
      test_file: "only_failures.rb",
      run_id: "test_retry_attempt_on_run_that_was_cut_short",
      arguments: { "--retry-failures" => "true" },
    ).value
    refute_worker_successful(worker3)
    assert_includes(worker3.stdout, "Cannot retry a run that was cut short during the previous attempt.")
  end

  def test_retry_attempt_on_run_that_was_cut_short_with_flaky_tests
    # In a naive implementation of short-circuiting runs, we could run into problems with retry mode.
    # If we abort a run after X flaky tests, and retry mode would only re-run those flaky tests. it
    # could easily succeed, even though many tests that would could have failed are not run at all.
    #
    # This tries tests this worst case sceario. The first 10 tests in the test suite we are executing
    # are flaky and pass on second attempt. The 11th test consistently fails. We should never get a
    # green build when running this test suite, even if we cut a run short after 10 failing tests.

    Tempfile.open("test_retry_attempt_on_run_that_was_cut_short_with_flaky_tests") do |f|
      worker1 = spawn_redis_worker(
        test_file: "all_flaky_failures.rb",
        run_id: "test_retry_attempt_on_run_that_was_cut_short_with_flaky_tests",
        arguments: { "--no-retry-failures" => "true", "--max-failures" => "10" },
        env: { "FLAKY_TRACKER_FILE" => f.path },
      ).value

      refute_worker_successful(worker1)
      assert_includes(worker1.stdout, "The run was cut short after reaching the limit of 10 test failures.")

      results = combined_results(run_id: "test_retry_attempt_on_run_that_was_cut_short_with_flaky_tests")
      refute_predicate(results, :passed?)
      assert_equal(100, results.size)
      assert_equal(0, results.passes)
      assert_equal(10, results.failures)
      assert_equal(0, results.requeues)

      worker2 = spawn_redis_worker(
        test_file: "all_flaky_failures.rb",
        run_id: "test_retry_attempt_on_run_that_was_cut_short_with_flaky_tests",
        arguments: { "--retry-failures" => "true", "--max-failures" => "10" },
        env: { "FLAKY_TRACKER_FILE" => f.path },
      ).value

      # The second attempt should never be successful.
      refute_worker_successful(worker2)

      # In our current implementation, we don't re-run any test and simply fail immediately.
      # We leave a message to the user telling them why.
      # The combined results should still reflect that the build is failing.
      assert_includes(worker2.stdout, "Cannot retry a run that was cut short during the previous attempt.")
      new_results = combined_results(run_id: "test_retry_attempt_on_run_that_was_cut_short_with_flaky_tests")
      refute_predicate(new_results, :passed?)
      assert_equal(0, new_results.requeues)

      # This should continue to be true, even if we do yet another attempt.
      worker3 = spawn_redis_worker(
        test_file: "all_flaky_failures.rb",
        run_id: "test_retry_attempt_on_run_that_was_cut_short_with_flaky_tests",
        arguments: { "--retry-failures" => "true", "--max-failures" => "10" },
        env: { "FLAKY_TRACKER_FILE" => f.path },
      ).value

      # Again, the third attempt shoudl not be successful
      refute_worker_successful(worker3)
    end
  end
end
