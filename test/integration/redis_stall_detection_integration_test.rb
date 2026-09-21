# typed: true
# frozen_string_literal: true

require "test_helper"

class RedisStallDetectionIntegrationTest < RedisIntegrationTest
  def test_missing_acks_counter_aborts_a_drained_run
    run_id = "test_missing_acks_counter_aborts_a_drained_run"
    worker_thread = spawn_redis_worker(
      test_file: "paced_passing_tests.rb",
      run_id: run_id,
      timeout: 5,
      arguments: {
        "--stall-timeout" => "0.1",
        "--test-batch-size" => "1",
      },
    )

    acks_key = "minitest/v3/#{run_id}/acks"
    wait_until("the worker acknowledged at least one test") do
      acks = @redis.get(acks_key)
      !acks.nil? && Integer(acks).between?(1, 19)
    end
    @redis.del(acks_key)

    worker = worker_thread.value
    refute_worker_successful(worker)
    assert_output_includes(worker, "lost required Redis coordinator state")
    assert_output_includes(worker, "COORDINATORSTATE missing")
    assert_output_includes(worker, "run_id=#{run_id}")
    assert_output_includes(worker, "The run is incomplete")
    assert_operator(@redis.ttl("minitest/v3/#{run_id}/stalled"), :>, 0)

    retry_worker = spawn_redis_worker(
      test_file: "paced_passing_tests.rb",
      run_id: run_id,
      arguments: { "--stall-timeout" => "0.1" },
    ).value
    assert_worker_successful(retry_worker)
    assert_output_includes(retry_worker, "Running the full test suite instead of a selective retry")
    assert_output_includes(retry_worker, "20 runs, 20 assertions, 20 passes, 0 failures, 0 errors")
    refute(@redis.exists?("minitest/v3/#{run_id}/stalled"))
  end

  def test_crashed_producer_eventually_aborts_followers
    workers = spawn_redis_workers(
      count: 2,
      test_file: "crashing_discovery_tests.rb",
      run_id: "test_crashed_producer_eventually_aborts_followers",
      timeout: 5,
      arguments: {
        "--stall-timeout" => "0.1",
        "--test-batch-size" => "1",
      },
      env: { "DISCOVERY_SLEEP_TIME" => "0.2" },
    ).map(&:value)

    refute(workers.any? { |worker| worker.status.success? }, boxed_workers_output(workers))
    output = workers_output(workers)
    assert_includes(output, "inconsistent Redis coordinator state")
    assert_includes(output, "production_complete=false")
  end

  def test_missing_stream_aborts_when_counters_are_incomplete
    run_id = "test_missing_stream_aborts_when_counters_are_incomplete"
    worker_thread = spawn_redis_worker(
      test_file: "paced_passing_tests.rb",
      run_id: run_id,
      timeout: 5,
      arguments: { "--test-batch-size" => "1" },
    )

    acks_key = "minitest/v3/#{run_id}/acks"
    wait_until("the worker acknowledged at least one test") do
      acks = @redis.get(acks_key)
      !acks.nil? && Integer(acks).between?(1, 19)
    end
    @redis.del("minitest/v3/#{run_id}/queue")

    worker = worker_thread.value
    refute_worker_successful(worker)
    assert_output_includes(worker, "lost required Redis coordinator state")
    assert_output_includes(worker, "The run is incomplete")
    assert_operator(@redis.ttl("minitest/v3/#{run_id}/stalled"), :>, 0)
  end

  def test_script_cache_flush_reloads_and_continues
    run_id = "test_script_cache_flush_reloads_and_continues"
    worker_thread = spawn_redis_worker(
      test_file: "paced_passing_tests.rb",
      run_id: run_id,
      timeout: 5,
      arguments: { "--test-batch-size" => "1" },
    )

    wait_until("the worker committed multiple batches") do
      (@redis.get("minitest/v3/#{run_id}/acks") || "0").to_i >= 2
    end
    @redis.script(:flush)

    worker = worker_thread.value
    assert_worker_successful(worker)
    assert_output_includes(worker, "20 runs, 20 assertions, 20 passes, 0 failures, 0 errors")
    refute_includes(worker.stdout, "NOSCRIPT")
  end

  def test_expired_required_state_fails_closed_for_a_requeued_result
    worker = spawn_redis_worker(
      test_file: "paced_failing_test.rb",
      run_id: "test_expired_required_state_fails_closed_for_a_requeued_result",
      timeout: 5,
      arguments: {
        "--key-ttl" => "2",
        "--max-attempts" => "3",
        "--test-batch-size" => "1",
        "--test-timeout" => "5",
      },
      env: { "SLEEP_TIME" => "2.2" },
    ).value

    refute_worker_successful(worker)
    assert_output_includes(worker, "COORDINATORSTATE missing")
    assert_output_includes(worker, "The run is incomplete")
    refute_includes(worker.stdout, "Results: 0 runs")
  end

  def test_slow_test_discovery_is_kept_alive_by_producer_heartbeat
    workers = spawn_redis_workers(
      count: 2,
      test_file: "slow_discovery_tests.rb",
      run_id: "test_slow_test_discovery_is_kept_alive_by_producer_heartbeat",
      timeout: 5,
      arguments: {
        "--stall-timeout" => "0.1",
        "--test-batch-size" => "1",
      },
      env: { "DISCOVERY_SLEEP_TIME" => "0.6" },
    ).map(&:value)

    assert_all_workers_successful(workers)
    refute_includes(workers_output(workers), "inconsistent Redis coordinator state")
  end

  def test_completed_attempt_with_live_stream_is_taken_over_for_retry
    run_id = "test_completed_attempt_with_live_stream_is_taken_over_for_retry"
    old_configuration = Minitest::Distributed::Configuration.new(
      coordinator_uri: URI(@redis_uri),
      run_id: run_id,
      worker_id: "old-worker",
      key_ttl_seconds: 2,
      completion_grace_seconds: 0.1,
    )
    old_coordinator = T.cast(old_configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    old_coordinator.produce(test_selector: empty_test_selector)
    old_generation = String(@redis.get("minitest/v3/#{run_id}/attempt_generation"))
    @redis.set("minitest/v3/#{run_id}/completed_at", (Time.now.to_f - 60).to_s)
    @redis.set("minitest/v3/#{run_id}/retention_ttl", "4", ex: 4)
    T.unsafe(old_coordinator).send(:commit_results, [])
    assert_operator(@redis.ttl("minitest/v3/#{run_id}/acks"), :>, 2)

    new_configuration = Minitest::Distributed::Configuration.new(
      coordinator_uri: URI(@redis_uri),
      run_id: run_id,
      worker_id: "new-worker",
      key_ttl_seconds: 4,
      completion_grace_seconds: 0.1,
    )
    new_coordinator = T.cast(new_configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    new_coordinator.produce(test_selector: empty_test_selector)
    new_generation = String(@redis.get("minitest/v3/#{run_id}/attempt_generation"))

    refute_equal(old_generation, new_generation)
    assert_equal("4", @redis.get("minitest/v3/#{run_id}/retention_ttl"))
    groups = @redis.xinfo("groups", "minitest/v3/#{run_id}/queue")
    assert_includes(groups.map { |group| group.fetch("name") }, "minitest-distributed-v3-#{new_generation}")

    T.unsafe(old_coordinator).send(:cleanup)
    assert(@redis.exists?("minitest/v3/#{run_id}/queue"), "old cleanup deleted the retry stream")
  ensure
    T.unsafe(new_coordinator).send(:cleanup) if defined?(new_coordinator) && new_coordinator
  end

  def test_immediate_retry_takes_over_a_completed_failed_stream_after_grace
    run_id = "test_immediate_retry_takes_over_a_completed_failed_stream_after_grace"
    worker1 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker1)

    generation = String(@redis.get("minitest/v3/#{run_id}/attempt_generation"))
    stream = "minitest/v3/#{run_id}/queue"
    @redis.xgroup(:create, stream, "minitest-distributed-v3-#{generation}", "0", mkstream: true)

    worker2 = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker2)
    refute_includes(worker2.stdout, "0 runs, 0 assertions")

    results = combined_results(run_id: run_id)
    assert_equal(1, results.requeues)
    assert_equal(1, results.failures)
    assert_equal(101, results.runs)
  end

  def test_nonterminal_aggregate_reader_rejects_partial_statistics
    run_id = "test_nonterminal_aggregate_reader_rejects_partial_statistics"
    @redis.set("minitest/v3/#{run_id}/runs", "0")
    configuration = redis_configuration(run_id: run_id, worker_id: "reader")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)

    error = T.unsafe(assert_raises(Redis::CommandError) { coordinator.combined_results })
    assert_includes(error.message, "partial aggregate statistics")
  end

  def test_terminal_aggregate_reader_rejects_missing_and_wrong_type_statistics
    run_id = "test_terminal_aggregate_reader_rejects_missing_and_wrong_type_statistics"
    worker = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker)

    assertions_key = "minitest/v3/#{run_id}/assertions"
    @redis.del(assertions_key)
    configuration = redis_configuration(run_id: run_id, worker_id: "reader")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    error = T.unsafe(assert_raises(Redis::CommandError) { coordinator.combined_results })
    assert_includes(error.message, "missing terminal statistic")

    @redis.lpush(assertions_key, "wrong-type")
    configuration = redis_configuration(run_id: run_id, worker_id: "second-reader")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    error = T.unsafe(assert_raises(Redis::CommandError) { coordinator.combined_results })
    assert_includes(error.message, "invalid statistic type")
  end

  def test_summary_does_not_pass_after_production_complete_is_lost
    run_id = "test_summary_does_not_pass_after_production_complete_is_lost"
    configuration = redis_configuration(run_id: run_id, worker_id: "worker")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    coordinator.produce(test_selector: empty_test_selector)
    coordinator.consume(reporter: Minitest::CompositeReporter.new)

    Tempfile.create("distributed-summary") do |output|
      summary = Minitest::Distributed::Reporters::DistributedSummaryReporter.new(
        output,
        { distributed: configuration, args: [] },
      )
      summary.start
      assert_predicate(summary, :passed?)

      @redis.del("minitest/v3/#{run_id}/production_complete")

      refute_predicate(summary, :passed?)
      summary.report
      output.rewind
      summary_output = output.read
      assert_includes(summary_output, "terminal coordinator state is invalid")
      refute_includes(T.unsafe(summary_output), "Results:")
    end
  end

  def test_publish_rejects_negative_completion_counters
    run_id = "test_publish_rejects_negative_completion_counters"
    configuration = redis_configuration(run_id: run_id, worker_id: "worker")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    coordinator.produce(test_selector: empty_test_selector)
    @redis.set("minitest/v3/#{run_id}/acks", "-1")
    @redis.set("minitest/v3/#{run_id}/size", "-1")

    error = T.unsafe(assert_raises(Redis::CommandError) do
      T.unsafe(coordinator).send(:publish_tests, [])
    end)
    assert_includes(error.message, "invalid completion counters")
  ensure
    T.unsafe(coordinator).send(:cleanup) if defined?(coordinator) && coordinator
  end

  def test_fractional_completion_grace_is_preserved_after_stream_cleanup
    run_id = "test_fractional_completion_grace_is_preserved_after_stream_cleanup"
    worker = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker)

    redis_time = @redis.time
    @redis.set("minitest/v3/#{run_id}/completed_at", redis_time[0] + redis_time[1] / 1_000_000.0 - 0.5)
    configuration = Minitest::Distributed::Configuration.new(
      coordinator_uri: URI(@redis_uri),
      run_id: run_id,
      worker_id: "late-worker",
      completion_grace_seconds: 1.0,
    )
    coordinator = T.cast(
      configuration.coordinator,
      Minitest::Distributed::Coordinators::RedisCoordinator,
    )

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    coordinator.produce(test_selector: empty_test_selector)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator(elapsed, :>, 0.25)
  ensure
    T.unsafe(coordinator).send(:cleanup) if defined?(coordinator) && coordinator
  end

  def test_completion_grace_bypass_is_scoped_to_the_generation_that_was_awaited
    run_id = "test_completion_grace_bypass_is_scoped_to_the_generation_that_was_awaited"
    worker = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker)

    slow_configuration = Minitest::Distributed::Configuration.new(
      coordinator_uri: URI(@redis_uri),
      run_id: run_id,
      worker_id: "slow-retry",
      completion_grace_seconds: 1.0,
    )
    slow_retry = T.cast(
      slow_configuration.coordinator,
      Minitest::Distributed::Coordinators::RedisCoordinator,
    )
    slow_thread = Thread.new { slow_retry.produce(test_selector: empty_test_selector) }

    sleep(0.7)
    fast_configuration = Minitest::Distributed::Configuration.new(
      coordinator_uri: URI(@redis_uri),
      run_id: run_id,
      worker_id: "fast-retry",
      completion_grace_seconds: 0.1,
    )
    fast_retry = T.cast(
      fast_configuration.coordinator,
      Minitest::Distributed::Coordinators::RedisCoordinator,
    )
    fast_retry.produce(test_selector: empty_test_selector)
    fast_generation = String(@redis.get("minitest/v3/#{run_id}/attempt_generation"))
    fast_completed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    slow_thread.join(3)
    refute_predicate(slow_thread, :alive?)
    elapsed_after_fast_completion = Process.clock_gettime(Process::CLOCK_MONOTONIC) - fast_completed_at
    assert_operator(elapsed_after_fast_completion, :>, 0.6)
    refute_equal(fast_generation, @redis.get("minitest/v3/#{run_id}/attempt_generation"))
  ensure
    slow_thread&.kill
    slow_thread&.join
    T.unsafe(slow_retry).send(:cleanup) if defined?(slow_retry) && slow_retry
    T.unsafe(fast_retry).send(:cleanup) if defined?(fast_retry) && fast_retry
  end

  def test_completed_at_uses_numeric_microsecond_arithmetic
    run_id = "test_completed_at_uses_numeric_microsecond_arithmetic"
    configuration = redis_configuration(run_id: run_id, worker_id: "worker")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)

    Timeout.timeout(2) do
      loop do
        microseconds = @redis.time.fetch(1)
        break if microseconds.between?(3_000, 8_000)
      end
    end
    coordinator.produce(test_selector: empty_test_selector)

    completed_at = Float(@redis.get("minitest/v3/#{run_id}/completed_at"))
    redis_time = @redis.time
    current_time = redis_time[0] + redis_time[1] / 1_000_000.0
    assert_in_delta(current_time, completed_at, 0.1)
  ensure
    T.unsafe(coordinator).send(:cleanup) if defined?(coordinator) && coordinator
  end

  def test_old_attempt_cannot_clean_up_a_new_generation
    run_id = "test_old_attempt_cannot_clean_up_a_new_generation"
    old_configuration = redis_configuration(run_id: run_id, worker_id: "old-worker")
    old_coordinator = T.cast(old_configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    old_coordinator.produce(test_selector: empty_test_selector)
    old_generation = String(@redis.get("minitest/v3/#{run_id}/attempt_generation"))

    new_coordinator = T.let(nil, T.nilable(Minitest::Distributed::Coordinators::RedisCoordinator))
    capture_io do
      T.unsafe(old_coordinator).send(:abort_with_diagnostic, "old attempt stalled")

      new_configuration = redis_configuration(run_id: run_id, worker_id: "new-worker")
      new_coordinator = T.cast(new_configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
      T.must(new_coordinator).produce(test_selector: empty_test_selector)
    end
    new_generation = String(@redis.get("minitest/v3/#{run_id}/attempt_generation"))
    refute_equal(old_generation, new_generation)

    assert_raises(Redis::CommandError) do
      T.unsafe(old_coordinator).send(
        :adjust_combined_results,
        Minitest::Distributed::ResultAggregate.new(size: 123),
      )
    end
    assert_raises(Redis::CommandError) do
      T.unsafe(old_coordinator).send(:publish_tests, [])
    end
    assert_equal(0, Integer(@redis.get("minitest/v3/#{run_id}/size")))

    T.unsafe(old_coordinator).send(:cleanup)

    assert(@redis.exists?("minitest/v3/#{run_id}/queue"), "old cleanup deleted the new attempt's stream")
    groups = @redis.xinfo("groups", "minitest/v3/#{run_id}/queue")
    assert_includes(groups.map { |group| group.fetch("name") }, "minitest-distributed-v3-#{new_generation}")
  ensure
    T.unsafe(new_coordinator).send(:cleanup) if new_coordinator
  end

  def test_missing_generation_aborts_locally_without_deleting_shared_stream
    run_id = "test_missing_generation_aborts_locally_without_deleting_shared_stream"
    configuration = redis_configuration(run_id: run_id, worker_id: "worker")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    coordinator.produce(test_selector: empty_test_selector)
    @redis.del("minitest/v3/#{run_id}/attempt_generation")

    capture_io do
      T.unsafe(coordinator).send(:abort_with_diagnostic, "generation missing")
    end

    assert_predicate(coordinator, :aborted?)
    assert_equal("generation missing", coordinator.stall_diagnostic)
    assert(@redis.exists?("minitest/v3/#{run_id}/queue"), "unowned abort deleted the shared stream")
    refute(@redis.exists?("minitest/v3/#{run_id}/stalled"))
  end

  def test_commit_rejects_inconsistent_aggregate_and_negative_assertions_before_ack
    run_id = "test_commit_rejects_inconsistent_aggregate_and_negative_assertions_before_ack"
    fixture_class = T.let(Class.new(Minitest::Test), T.class_of(Minitest::Test))
    fixture_class.send(:define_method, :test_passes) {}
    T.unsafe(Object).const_set(:CommitValidationFixture, fixture_class)
    runnable = fixture_class.new(:test_passes)
    selector = empty_test_selector
    selector.define_singleton_method(:tests) { [runnable] }

    configuration = redis_configuration(run_id: run_id, worker_id: "worker")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    coordinator.produce(test_selector: selector)
    claims = T.cast(
      T.unsafe(coordinator).send(:claim_fresh_runnables, block: 1),
      T::Array[Minitest::Distributed::EnqueuedRunnable],
    )
    result = claims.fetch(0).instantiate_runnable.run
    @redis.set("minitest/v3/#{run_id}/runs", "1")

    aggregate_error = T.unsafe(assert_raises(Redis::CommandError) do
      T.unsafe(coordinator).send(:commit_results, [[claims.fetch(0), result]])
    end)
    assert_includes(aggregate_error.message, "inconsistent aggregate statistics")
    assert_equal("0", @redis.get("minitest/v3/#{run_id}/acks"))

    @redis.set("minitest/v3/#{run_id}/runs", "0")
    result.assertions = -1
    payload_error = T.unsafe(assert_raises(Redis::CommandError) do
      T.unsafe(coordinator).send(:commit_results, [[claims.fetch(0), result]])
    end)
    assert_includes(payload_error.message, "invalid result payload")
    assert_equal("0", @redis.get("minitest/v3/#{run_id}/acks"))

    capture_io { T.unsafe(coordinator).send(:abort_with_diagnostic, "superseded for test") }
    replacement_configuration = redis_configuration(run_id: run_id, worker_id: "replacement")
    replacement = T.cast(
      replacement_configuration.coordinator,
      Minitest::Distributed::Coordinators::RedisCoordinator,
    )
    replacement.produce(test_selector: empty_test_selector)
    result.assertions = 0
    discarded = T.unsafe(coordinator).send(:commit_results, [[claims.fetch(0), result]])
    assert_predicate(discarded.fetch(0).commit, :failure?)
  ensure
    T.unsafe(coordinator).send(:cleanup) if defined?(coordinator) && coordinator
    T.unsafe(replacement).send(:cleanup) if defined?(replacement) && replacement
    T.unsafe(Object).send(:remove_const, :CommitValidationFixture) if Object.const_defined?(:CommitValidationFixture)
  end

  def test_commit_after_truncation_marker_does_not_ack_or_complete_the_run
    run_id = "test_commit_after_truncation_marker_does_not_ack_or_complete_the_run"
    fixture_class = T.let(Class.new(Minitest::Test), T.class_of(Minitest::Test))
    fixture_class.send(:define_method, :test_passes) {}
    T.unsafe(Object).const_set(:TruncationRaceFixture, fixture_class)
    runnable = fixture_class.new(:test_passes)
    selector = empty_test_selector
    selector.define_singleton_method(:tests) { [runnable] }

    configuration = redis_configuration(run_id: run_id, worker_id: "worker")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    coordinator.produce(test_selector: selector)
    claims = T.cast(
      T.unsafe(coordinator).send(:claim_fresh_runnables, block: 1),
      T::Array[Minitest::Distributed::EnqueuedRunnable],
    )
    assert_equal(1, claims.length)

    T.unsafe(coordinator).send(:mark_run_truncated)
    result = claims.fetch(0).instantiate_runnable.run
    committed_results = T.unsafe(coordinator).send(:commit_results, [[claims.fetch(0), result]])

    assert_predicate(committed_results.fetch(0).commit, :failure?)
    assert_equal("0", @redis.get("minitest/v3/#{run_id}/acks"))
    assert_equal("1", @redis.get("minitest/v3/#{run_id}/truncated"))
    refute(@redis.exists?("minitest/v3/#{run_id}/completed_at"))
    refute(@redis.exists?("minitest/v3/#{run_id}/retry_snapshot_digest"))
    Tempfile.create("truncated-summary") do |output|
      summary = Minitest::Distributed::Reporters::DistributedSummaryReporter.new(
        output,
        { distributed: configuration, args: [] },
      )
      summary.start
      summary.report
      output.rewind
      summary_output = output.read
      assert_includes(summary_output, "another worker reached the max-failures limit")
      refute_includes(T.unsafe(summary_output), "previous attempt")
    end

    truncated_generation = String(@redis.get("minitest/v3/#{run_id}/attempt_generation"))
    @redis.expire("minitest/v3/#{run_id}/truncated_generation", 1)
    replacement_configuration = redis_configuration(run_id: run_id, worker_id: "replacement")
    replacement = T.cast(
      replacement_configuration.coordinator,
      Minitest::Distributed::Coordinators::RedisCoordinator,
    )
    replacement.produce(test_selector: empty_test_selector)
    refute_equal(truncated_generation, @redis.get("minitest/v3/#{run_id}/attempt_generation"))
    assert_predicate(replacement, :aborted?)
    assert_operator(@redis.ttl("minitest/v3/#{run_id}/truncated_generation"), :>, 60)

    discarded_after_takeover = T.unsafe(coordinator).send(:commit_results, [[claims.fetch(0), result]])
    assert_predicate(discarded_after_takeover.fetch(0).commit, :failure?)
    assert_predicate(coordinator, :current_attempt_truncated?)
    refute(@redis.exists?("minitest/v3/#{run_id}/stalled"))

    follower_configuration = redis_configuration(run_id: run_id, worker_id: "truncated-follower")
    follower = T.cast(
      follower_configuration.coordinator,
      Minitest::Distributed::Coordinators::RedisCoordinator,
    )
    follower.produce(test_selector: empty_test_selector)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    follower.consume(reporter: Minitest::CompositeReporter.new)
    assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at, :<, 0.1)
    assert_predicate(follower, :aborted?)
    assert(@redis.exists?("minitest/v3/#{run_id}/queue"), "truncated follower cleaned up the replacement stream")
  ensure
    T.unsafe(coordinator).send(:cleanup) if defined?(coordinator) && coordinator
    T.unsafe(replacement).send(:cleanup) if defined?(replacement) && replacement
    T.unsafe(follower).send(:cleanup) if defined?(follower) && follower
    T.unsafe(Object).send(:remove_const, :TruncationRaceFixture) if Object.const_defined?(:TruncationRaceFixture)
  end

  def test_completed_attempt_is_not_marked_truncated
    run_id = "test_completed_attempt_is_not_marked_truncated"
    configuration = redis_configuration(run_id: run_id, worker_id: "worker")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    coordinator.produce(test_selector: empty_test_selector)

    T.unsafe(coordinator).send(:mark_run_truncated)

    refute(@redis.exists?("minitest/v3/#{run_id}/truncated"))
    refute_predicate(coordinator, :aborted?)
  ensure
    T.unsafe(coordinator).send(:cleanup) if defined?(coordinator) && coordinator
  end

  def test_missing_generation_fails_closed_when_truncation_cannot_be_persisted
    run_id = "test_missing_generation_fails_closed_when_truncation_cannot_be_persisted"
    configuration = redis_configuration(run_id: run_id, worker_id: "worker")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    coordinator.produce(test_selector: empty_test_selector)
    @redis.del("minitest/v3/#{run_id}/attempt_generation")

    capture_io do
      T.unsafe(coordinator).send(:mark_run_truncated)
    end

    assert_predicate(coordinator, :aborted?)
    assert_includes(T.must(coordinator.stall_diagnostic), "could not persist max-failures truncation state")
    refute(@redis.exists?("minitest/v3/#{run_id}/truncated"))
  end

  def test_wrong_type_production_heartbeat_emits_a_coordinator_diagnostic
    run_id = "test_wrong_type_production_heartbeat_emits_a_coordinator_diagnostic"
    leader = T.cast(
      redis_configuration(run_id: run_id, worker_id: "leader").coordinator,
      Minitest::Distributed::Coordinators::RedisCoordinator,
    )
    follower = T.cast(
      redis_configuration(run_id: run_id, worker_id: "follower").coordinator,
      Minitest::Distributed::Coordinators::RedisCoordinator,
    )
    discovery_started = Queue.new
    release_discovery = Queue.new
    blocking_selector = empty_test_selector
    blocking_selector.define_singleton_method(:tests) do
      discovery_started.push(true)
      release_discovery.pop
      []
    end

    leader_thread = Thread.new { leader.produce(test_selector: blocking_selector) }
    discovery_started.pop
    follower.produce(test_selector: empty_test_selector)
    @redis.del("minitest/v3/#{run_id}/production_heartbeat")
    @redis.lpush("minitest/v3/#{run_id}/production_heartbeat", "wrong-type")

    capture_io do
      follower.consume(reporter: Minitest::CompositeReporter.new)
    end

    assert_predicate(follower, :aborted?)
    assert_includes(T.must(follower.stall_diagnostic), "production_heartbeat has Redis type list")
  ensure
    leader_thread&.kill
    leader_thread&.join
  end

  def test_runtime_retention_mismatch_uses_coordinator_diagnostic
    run_id = "test_runtime_retention_mismatch_uses_coordinator_diagnostic"
    worker_thread = spawn_redis_worker(
      test_file: "paced_passing_tests.rb",
      run_id: run_id,
      timeout: 5,
      arguments: { "--test-batch-size" => "1" },
    )
    acks_key = "minitest/v3/#{run_id}/acks"
    wait_until("the worker acknowledges a test") do
      acks = @redis.get(acks_key)
      !acks.nil? && Integer(acks).between?(1, 19)
    end
    @redis.set("minitest/v3/#{run_id}/retention_ttl", "1", ex: 30)

    worker = worker_thread.value
    refute_worker_successful(worker)
    assert_output_includes(worker, "lost required Redis coordinator state")
    assert_output_includes(worker, "COORDINATORCONFIG")
    refute_includes(worker.stdout, "Redis::CommandError")
  end

  def test_native_wrongtype_from_direct_stream_commands_fails_closed
    run_id = "test_native_wrongtype_from_direct_stream_commands_fails_closed"
    leader = T.cast(
      redis_configuration(run_id: run_id, worker_id: "leader").coordinator,
      Minitest::Distributed::Coordinators::RedisCoordinator,
    )
    follower = T.cast(
      redis_configuration(run_id: run_id, worker_id: "follower").coordinator,
      Minitest::Distributed::Coordinators::RedisCoordinator,
    )
    discovery_started = Queue.new
    release_discovery = Queue.new
    blocking_selector = empty_test_selector
    blocking_selector.define_singleton_method(:tests) do
      discovery_started.push(true)
      release_discovery.pop
      []
    end

    leader_thread = Thread.new { leader.produce(test_selector: blocking_selector) }
    discovery_started.pop
    follower.produce(test_selector: empty_test_selector)
    @redis.del("minitest/v3/#{run_id}/queue")
    @redis.set("minitest/v3/#{run_id}/queue", "wrong-type")

    capture_io do
      follower.consume(reporter: Minitest::CompositeReporter.new)
    end

    assert_predicate(follower, :aborted?)
    assert_includes(T.must(follower.stall_diagnostic), "WRONGTYPE")
    assert(@redis.exists?("minitest/v3/#{run_id}/stalled"))
  ensure
    leader_thread&.kill
    leader_thread&.join
  end

  def test_invalid_statistic_emits_diagnostic_before_aborting
    run_id = "test_invalid_statistic_emits_diagnostic_before_aborting"
    configuration = redis_configuration(run_id: run_id, worker_id: "worker")
    coordinator = T.cast(configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    coordinator.produce(test_selector: empty_test_selector)
    @redis.set("minitest/v3/#{run_id}/acks", "not-an-integer")
    T.unsafe(coordinator).instance_variable_set(:@combined_results, nil)

    capture_io do
      coordinator.consume(reporter: Minitest::CompositeReporter.new)
    end

    assert_predicate(coordinator, :aborted?)
    assert_includes(T.must(coordinator.stall_diagnostic), "lost required Redis coordinator state")
    assert_includes(T.must(coordinator.stall_diagnostic), "invalid statistic")

    Tempfile.create("distributed-summary") do |output|
      summary = Minitest::Distributed::Reporters::DistributedSummaryReporter.new(
        output,
        { distributed: configuration, args: [] },
      )
      summary.start
      summary.report
      output.rewind
      summary_output = output.read
      assert_includes(summary_output, "Combined results are unavailable")
      refute_includes(T.unsafe(summary_output), "not-an-integer")
    end
  end

  def test_pending_tests_warn_but_do_not_abort
    workers = spawn_redis_workers(
      count: 2,
      test_file: "slow_test.rb",
      run_id: "test_pending_tests_warn_but_do_not_abort",
      timeout: 5,
      arguments: {
        "--stall-timeout" => "0.05",
        "--test-batch-size" => "1",
        "--test-timeout" => "1",
      },
      env: { "SLEEP_TIME" => "0.5" },
    ).map(&:value)

    assert_all_workers_successful(workers)

    output = workers_output(workers)
    assert_includes(output, "Redis still has pending tests")
    assert_includes(output, "pending=1")
    refute_includes(output, "inconsistent Redis coordinator state")
  end

  private

  def redis_configuration(run_id:, worker_id:)
    Minitest::Distributed::Configuration.new(
      coordinator_uri: URI(@redis_uri),
      run_id: run_id,
      worker_id: worker_id,
    )
  end

  def empty_test_selector
    selector = Minitest::Distributed::TestSelector.allocate
    selector.define_singleton_method(:tests) { [] }
    selector
  end

  def wait_until(description, timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk("Timed out waiting for #{description}") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep(0.005)
    end
  end
end
