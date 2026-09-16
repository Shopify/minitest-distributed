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

    acks_key = "minitest/#{run_id}/acks"
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
    assert_operator(@redis.ttl("minitest/#{run_id}/stalled"), :>, 0)

    retry_worker = spawn_redis_worker(
      test_file: "paced_passing_tests.rb",
      run_id: run_id,
      arguments: { "--stall-timeout" => "0.1" },
    ).value
    assert_worker_successful(retry_worker)
    assert_output_includes(retry_worker, "Running the full test suite instead of a selective retry")
    assert_output_includes(retry_worker, "20 runs, 20 assertions, 20 passes, 0 failures, 0 errors")
    refute(@redis.exists?("minitest/#{run_id}/stalled"))
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

    acks_key = "minitest/#{run_id}/acks"
    wait_until("the worker acknowledged at least one test") do
      acks = @redis.get(acks_key)
      !acks.nil? && Integer(acks).between?(1, 19)
    end
    @redis.del("minitest/#{run_id}/queue")

    worker = worker_thread.value
    refute_worker_successful(worker)
    assert_output_includes(worker, "lost required Redis coordinator state")
    assert_output_includes(worker, "The run is incomplete")
    assert_operator(@redis.ttl("minitest/#{run_id}/stalled"), :>, 0)
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
      (@redis.get("minitest/#{run_id}/acks") || "0").to_i >= 2
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
        "--key-ttl" => "1",
        "--max-attempts" => "3",
        "--test-batch-size" => "1",
        "--test-timeout" => "5",
      },
      env: { "SLEEP_TIME" => "1.2" },
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
    old_configuration = redis_configuration(run_id: run_id, worker_id: "old-worker")
    old_coordinator = T.cast(old_configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    old_coordinator.produce(test_selector: empty_test_selector)
    old_generation = String(@redis.get("minitest/#{run_id}/attempt_generation"))

    new_configuration = redis_configuration(run_id: run_id, worker_id: "new-worker")
    new_coordinator = T.cast(new_configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    new_coordinator.produce(test_selector: empty_test_selector)
    new_generation = String(@redis.get("minitest/#{run_id}/attempt_generation"))

    refute_equal(old_generation, new_generation)
    groups = @redis.xinfo("groups", "minitest/#{run_id}/queue")
    assert_includes(groups.map { |group| group.fetch("name") }, "minitest-distributed-#{new_generation}")

    T.unsafe(old_coordinator).send(:cleanup)
    assert(@redis.exists?("minitest/#{run_id}/queue"), "old cleanup deleted the retry stream")
  ensure
    T.unsafe(new_coordinator).send(:cleanup) if defined?(new_coordinator) && new_coordinator
  end

  def test_old_attempt_cannot_clean_up_a_new_generation
    run_id = "test_old_attempt_cannot_clean_up_a_new_generation"
    old_configuration = redis_configuration(run_id: run_id, worker_id: "old-worker")
    old_coordinator = T.cast(old_configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
    old_coordinator.produce(test_selector: empty_test_selector)
    old_generation = String(@redis.get("minitest/#{run_id}/attempt_generation"))

    new_coordinator = T.let(nil, T.nilable(Minitest::Distributed::Coordinators::RedisCoordinator))
    capture_io do
      T.unsafe(old_coordinator).send(:abort_with_diagnostic, "old attempt stalled")

      new_configuration = redis_configuration(run_id: run_id, worker_id: "new-worker")
      new_coordinator = T.cast(new_configuration.coordinator, Minitest::Distributed::Coordinators::RedisCoordinator)
      T.must(new_coordinator).produce(test_selector: empty_test_selector)
    end
    new_generation = String(@redis.get("minitest/#{run_id}/attempt_generation"))
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
    assert_equal(0, Integer(@redis.get("minitest/#{run_id}/size")))

    T.unsafe(old_coordinator).send(:cleanup)

    assert(@redis.exists?("minitest/#{run_id}/queue"), "old cleanup deleted the new attempt's stream")
    groups = @redis.xinfo("groups", "minitest/#{run_id}/queue")
    assert_includes(groups.map { |group| group.fetch("name") }, "minitest-distributed-#{new_generation}")
  ensure
    T.unsafe(new_coordinator).send(:cleanup) if new_coordinator
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
