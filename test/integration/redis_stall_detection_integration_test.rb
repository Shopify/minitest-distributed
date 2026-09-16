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
    assert_output_includes(worker, "minitest-distributed detected inconsistent Redis coordinator state")
    assert_output_includes(worker, "run_id=#{run_id}")
    assert_output_includes(worker, "pending=0 lag=0")
    assert_output_includes(worker, "the run cannot make further progress")
    refute_includes(worker.stdout, "Cannot retry a run that was cut short during the previous attempt")
    assert_operator(@redis.ttl("minitest/#{run_id}/stalled"), :>, 0)

    retry_worker = spawn_redis_worker(
      test_file: "paced_passing_tests.rb",
      run_id: run_id,
      arguments: { "--stall-timeout" => "0.1" },
    ).value
    refute_worker_successful(retry_worker)
    assert_output_includes(retry_worker, "Cannot retry a run that was cut short during the previous attempt")
  end

  def test_missing_production_marker_eventually_aborts
    run_id = "test_missing_production_marker_eventually_aborts"
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
    @redis.del(acks_key, "minitest/#{run_id}/production_complete")

    worker = worker_thread.value
    refute_worker_successful(worker)
    assert_output_includes(worker, "inconsistent Redis coordinator state")
    assert_output_includes(worker, "production_complete=false")
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
    assert_output_includes(worker, "lost its Redis stream or consumer group")
    assert_output_includes(worker, "The run is incomplete")
    assert_operator(@redis.ttl("minitest/#{run_id}/stalled"), :>, 0)
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

  def wait_until(description, timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk("Timed out waiting for #{description}") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep(0.005)
    end
  end
end
