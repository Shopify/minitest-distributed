# typed: true
# frozen_string_literal: true

require "test_helper"

# Shared test cases that should pass identically with and without lazy loading.
# Test methods are dynamically defined with names indicating the loading mode.
module RedisCoordinatorSharedTests
  class << self
    def included(base)
      base.class_eval do
        define_method("test_no_tests_#{loading_mode}") do
          runner = spawn_redis_worker(
            test_file: "no_tests.rb",
            run_id: "#{test_name_prefix}_no_tests",
            lazy_load: lazy_load_enabled?,
          ).value

          assert_worker_successful(runner)
          assert_output_includes(runner, "0 runs, 0 assertions, 0 passes, 0 failures, 0 errors")

          results = combined_results(run_id: "#{test_name_prefix}_no_tests")
          assert_predicate(results, :passed?)
          assert_equal(0, results.unique_runs)
          assert_equal(0, results.passes)
          assert_equal(0, results.failures)
          assert_equal(0, results.errors)
          assert_equal(0, results.skips)
        end

        define_method("test_passing_tests_with_one_worker_#{loading_mode}") do
          runner = spawn_redis_worker(
            test_file: "passing_tests.rb",
            run_id: "#{test_name_prefix}_passing_one",
            lazy_load: lazy_load_enabled?,
          ).value

          assert_worker_successful(runner)
          assert_output_includes(runner, "100 runs, 100 assertions, 100 passes, 0 failures, 0 errors")

          results = combined_results(run_id: "#{test_name_prefix}_passing_one")
          assert_predicate(results, :passed?)
          assert_equal(100, results.passes)
          assert_equal(0, results.failures)
          assert_equal(0, results.errors)
          assert_equal(0, results.skips)
        end

        define_method("test_failing_tests_with_one_worker_and_two_attempts_#{loading_mode}") do
          runner = spawn_redis_worker(
            test_file: "failing_tests.rb",
            run_id: "#{test_name_prefix}_failing_one_two_attempts",
            arguments: {
              "--test-timeout" => "1",
              "--test-batch-size" => "1",
              "--max-attempts" => "2",
            },
            lazy_load: lazy_load_enabled?,
          ).value

          refute_worker_successful(runner)
          assert_output_includes(runner, "101 runs, 101 assertions, 99 passes, 1 failures, 0 errors, 1 re-queued")

          results = combined_results(run_id: "#{test_name_prefix}_failing_one_two_attempts")
          refute_predicate(results, :passed?)
          assert_equal(100, results.unique_runs)
          assert_equal(99, results.passes)
          assert_equal(1, results.failures)
          assert_equal(0, results.errors)
          assert_equal(0, results.skips)
        end

        define_method("test_passing_tests_with_multiple_workers_#{loading_mode}") do
          workers = spawn_redis_workers(
            count: 3,
            test_file: "passing_tests.rb",
            run_id: "#{test_name_prefix}_passing_multi",
            lazy_load: lazy_load_enabled?,
          ).map(&:value)

          assert_all_workers_successful(workers)

          results = combined_results(run_id: "#{test_name_prefix}_passing_multi")
          assert_predicate(results, :passed?)
          assert_equal(100, results.unique_runs)
          assert_equal(100, results.passes)
          assert_equal(0, results.failures)
          assert_equal(0, results.errors)
          assert_equal(0, results.skips)
        end

        define_method("test_failing_tests_with_multiple_workers_#{loading_mode}") do
          workers = spawn_redis_workers(
            count: 3,
            test_file: "failing_tests.rb",
            run_id: "#{test_name_prefix}_failing_multi",
            arguments: {
              "--test-timeout" => "1",
              "--test-batch-size" => "1",
              "--max-attempts" => "3",
            },
            lazy_load: lazy_load_enabled?,
          ).map(&:value)

          assert_some_workers_failed(workers)

          results = combined_results(run_id: "#{test_name_prefix}_failing_multi")
          refute_predicate(results, :passed?)
          assert_equal(100, results.unique_runs)
          assert_equal(99, results.passes)
          assert_equal(1, results.failures)
          assert_equal(0, results.errors)
          assert_equal(0, results.skips)
        end

        define_method("test_crashing_worker_#{loading_mode}") do
          Tempfile.open("#{test_name_prefix}_crashing_worker") do |f|
            worker = spawn_redis_worker(
              test_file: "crashing_tests.rb",
              run_id: "#{test_name_prefix}_crashing_worker",
              env: { "CRASH_TRACKER_FILE" => f.path },
              lazy_load: lazy_load_enabled?,
            ).value

            assert_equal(9, worker.status.termsig, "Expected worker to have been KILLed.\n#{boxed_workers_output([worker])}")
          end

          results = combined_results(run_id: "#{test_name_prefix}_crashing_worker")
          refute_predicate(results, :complete?)
          assert_predicate(results, :passed?)
        end

        define_method("test_crashing_worker_with_multiple_workers_#{loading_mode}") do
          workers = Tempfile.open("#{test_name_prefix}_crashing_multi") do |f|
            spawn_redis_workers(
              count: 2,
              test_file: "crashing_tests.rb",
              run_id: "#{test_name_prefix}_crashing_multi",
              arguments: { "--test-batch-size" => "5", "--test-timeout" => "0.1", "--max-attempts" => "3" },
              env: { "CRASH_TRACKER_FILE" => f.path },
              lazy_load: lazy_load_enabled?,
            ).map(&:value)
          end

          grouped_workers = workers.group_by { |worker| !!worker.status.success? }
          assert_equal(1, grouped_workers[true]&.size || 0, "Expected 1 worker to succeed\n#{boxed_workers_output(workers)}")
          assert_equal(1, grouped_workers[false]&.size || 0, "Expected 1 worker to fail\n#{boxed_workers_output(workers)}")

          crashed_worker = grouped_workers[false][0]
          successful_worker = grouped_workers[true][0]

          assert_output_includes(successful_worker, "WARNING: The following tests were reclaimed from another worker")
          assert_equal("KILL", Signal.signame(crashed_worker.status.termsig))

          results = combined_results(run_id: "#{test_name_prefix}_crashing_multi")
          assert_predicate(results, :passed?)
          assert_equal(100, results.unique_runs)
          assert_equal(100, results.passes)
          assert_equal(0, results.failures)
          assert_equal(0, results.errors)
          assert_equal(0, results.skips)
        end

        define_method("test_test_that_is_too_slow_with_enough_workers_#{loading_mode}") do
          workers = spawn_redis_workers(
            count: 4,
            test_file: "slow_test.rb",
            run_id: "#{test_name_prefix}_slow_enough_workers",
            arguments: { "--test-batch-size" => "3", "--test-timeout" => "0.05", "--max-attempts" => "3" },
            env: { "SLEEP_TIME" => "2" },
            lazy_load: lazy_load_enabled?,
          ).map(&:value)

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

          results = combined_results(run_id: "#{test_name_prefix}_slow_enough_workers")
          refute_predicate(results, :passed?)
          assert_equal(100, results.acks)
          assert_equal(100, results.unique_runs)
          assert_equal(99, results.passes)
          assert_equal(1, results.failures)
          assert_equal(0, results.errors)
          assert_equal(0, results.skips)
        end

        define_method("test_test_that_is_too_slow_with_limited_workers_#{loading_mode}") do
          workers = spawn_redis_workers(
            count: 3,
            test_file: "slow_test.rb",
            run_id: "#{test_name_prefix}_slow_limited_workers",
            arguments: { "--test-batch-size" => "3", "--test-timeout" => "0.05", "--max-attempts" => "3" },
            env: { "SLEEP_TIME" => "1" },
            lazy_load: lazy_load_enabled?,
          ).map(&:value)

          assert_all_workers_successful(workers)
          output = workers_output(workers)
          assert_includes(output, "WARNING: The following tests were reclaimed from another worker:")

          results = combined_results(run_id: "#{test_name_prefix}_slow_limited_workers")
          assert_predicate(results, :passed?)
          assert_equal(100, results.acks)
          assert_equal(100, results.unique_runs)
          assert_equal(100, results.passes)
          assert_equal(0, results.failures)
          assert_equal(0, results.errors)
          assert_equal(0, results.skips)
        end

        define_method("test_flaky_test_fails_with_only_one_attempt_#{loading_mode}") do
          workers = Tempfile.open("#{test_name_prefix}_flaky_one_attempt") do |f|
            spawn_redis_workers(
              count: 3,
              test_file: "flaky_test.rb",
              run_id: "#{test_name_prefix}_flaky_one_attempt",
              arguments: { "--max-attempts" => "1", "--no-retry-failures" => "true" },
              env: { "FLAKY_TRACKER_FILE" => f.path },
              lazy_load: lazy_load_enabled?,
            ).map(&:value)
          end

          assert_some_workers_failed(workers)

          results = combined_results(run_id: "#{test_name_prefix}_flaky_one_attempt")
          refute_predicate(results, :passed?)
          assert_equal(99, results.passes)
          assert_equal(1, results.failures)
          assert_equal(0, results.requeues)
        end

        define_method("test_flaky_test_succeeds_after_second_attempt_with_single_worker_#{loading_mode}") do
          worker = Tempfile.open("#{test_name_prefix}_flaky_single") do |f|
            spawn_redis_worker(
              test_file: "flaky_test.rb",
              run_id: "#{test_name_prefix}_flaky_single",
              arguments: { "--max-attempts" => "3", "--no-retry-failures" => "true" },
              env: { "FLAKY_TRACKER_FILE" => f.path },
              lazy_load: lazy_load_enabled?,
            ).value
          end

          assert_worker_successful(worker)

          results = combined_results(run_id: "#{test_name_prefix}_flaky_single")
          assert_predicate(results, :passed?)
          assert_equal(100, results.passes)
          assert_equal(0, results.failures)
          assert_equal(1, results.requeues)
        end

        define_method("test_flaky_test_succeeds_after_second_attempt_with_multiple_workers_#{loading_mode}") do
          workers = Tempfile.open("#{test_name_prefix}_flaky_multi") do |f|
            spawn_redis_workers(
              count: 3,
              test_file: "flaky_test.rb",
              run_id: "#{test_name_prefix}_flaky_multi",
              arguments: { "--max-attempts" => "3", "--no-retry-failures" => "true" },
              env: { "FLAKY_TRACKER_FILE" => f.path },
              lazy_load: lazy_load_enabled?,
            ).map(&:value)
          end

          assert_all_workers_successful(workers)

          results = combined_results(run_id: "#{test_name_prefix}_flaky_multi")
          assert_predicate(results, :passed?)
          assert_equal(100, results.passes)
          assert_equal(0, results.failures)
          assert_equal(1, results.requeues)
        end

        define_method("test_max_failures_with_multiple_workers_#{loading_mode}") do
          workers = spawn_redis_workers(
            count: 3,
            test_file: "only_failures.rb",
            run_id: "#{test_name_prefix}_max_failures",
            arguments: { "--max-failures" => "10", "--no-retry-failures" => "true", "--test-batch-size" => "1" },
            lazy_load: lazy_load_enabled?,
          ).map(&:value)

          assert_some_workers_failed(workers)
          assert_includes(workers_output(workers), "The run was cut short after reaching the limit of 10 test failures.")

          results = combined_results(run_id: "#{test_name_prefix}_max_failures", max_failures: 10)
          refute_predicate(results, :passed?)
          assert_predicate(results, :valid?)
          assert_operator(results.failures, :>=, 10)
        end

        define_method("test_with_progress_#{loading_mode}") do
          workers = spawn_redis_workers(
            count: 2,
            test_file: "passing_tests.rb",
            run_id: "#{test_name_prefix}_progress",
            arguments: { "--progress" => "true", "--test-batch-size" => "5" },
            lazy_load: lazy_load_enabled?,
          ).map(&:value)

          assert_all_workers_successful(workers)

          output = workers_output(workers)
          assert_includes(output, "/100] PassingTests#test_pass_0")
          assert_includes(output, "/100] PassingTests#test_pass_99")
        end
      end
    end
  end
end

# Tests without lazy loading (baseline)
class RedisCoordinatorIntegrationEagerTest < RedisIntegrationTest
  class << self
    def loading_mode
      "eager"
    end
  end

  def lazy_load_enabled?
    false
  end

  def test_name_prefix
    "eager"
  end

  include RedisCoordinatorSharedTests
end

# Tests with lazy loading enabled
class RedisCoordinatorIntegrationLazyTest < RedisIntegrationTest
  class << self
    def loading_mode
      "lazy"
    end
  end

  def lazy_load_enabled?
    true
  end

  def test_name_prefix
    "lazy"
  end

  include RedisCoordinatorSharedTests
end

# Tests that don't need to run in both eager and lazy modes
class RedisCoordinatorIntegrationTest < RedisIntegrationTest
  def test_no_tests_with_read_timeout
    Toxiproxy[/redis/].downstream(:latency, latency: 100).apply do
      runner = spawn_redis_worker(
        test_file: "no_tests.rb",
        run_id: "test_no_tests_with_read_timeout",
      ).value

      assert_worker_successful(runner)
      assert_output_includes(runner, "0 runs, 0 assertions, 0 passes, 0 failures, 0 errors")
      results = combined_results(run_id: "test_no_tests_with_read_timeout")
      assert_predicate(results, :passed?)
      assert_equal(0, results.unique_runs)
      assert_equal(0, results.passes)
      assert_equal(0, results.failures)
      assert_equal(0, results.errors)
      assert_equal(0, results.skips)
    end
  end

  def test_with_redis_log
    Tempfile.open("test_with_redis_log") do |f|
      workers = spawn_redis_workers(
        count: 2,
        test_file: "passing_tests.rb",
        run_id: "test_with_redis_log",
        arguments: { "--test-batch-size" => "5" },
        env: { "MINITEST_DISTRIBUTED_REDIS_LOG" => f.path },
      ).map(&:value)

      assert_all_workers_successful(workers)

      log = File.read(T.must(f.path))
      assert_includes(log, "xpending")
      assert_includes(log, "mget")
      assert_includes(log, "xack")
    end
  end
end
