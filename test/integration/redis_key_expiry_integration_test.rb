# typed: true
# frozen_string_literal: true

require "test_helper"

class RedisKeyExpiryIntegrationTest < RedisIntegrationTest
  def test_run_keys_have_an_expiry_after_a_completed_run
    run_id = "test_run_keys_have_an_expiry_after_a_completed_run"

    worker = spawn_redis_worker(test_file: "passing_tests.rb", run_id: run_id).value
    assert_worker_successful(worker)

    keys = run_keys(run_id)
    refute_empty(keys, "expected the run to leave statistics keys in Redis")

    keys.each do |key|
      ttl = @redis.ttl(key)

      # -1 means "exists, but has no expiry": the leak this test guards against.
      assert_operator(ttl, :>, 0, "#{key} has no expiry (TTL #{ttl})")
      assert_operator(ttl, :<=, Minitest::Distributed::Configuration::DEFAULT_KEY_TTL_SECONDS, "#{key} TTL too high")
    end
  end

  def test_run_keys_have_an_expiry_after_a_failed_run
    run_id = "test_run_keys_have_an_expiry_after_a_failed_run"

    worker = spawn_redis_worker(test_file: "failing_tests.rb", run_id: run_id).value
    refute_worker_successful(worker)

    keys = run_keys(run_id)

    # A failed run keeps its failure list around for retry mode, so the expiry has
    # to cover the list keys too, not just the counters.
    assert_includes(keys, "minitest/#{run_id}/failed_list")

    keys.each do |key|
      assert_operator(@redis.ttl(key), :>, 0, "#{key} has no expiry")
    end
  end

  def test_key_ttl_is_configurable
    run_id = "test_key_ttl_is_configurable"

    worker = spawn_redis_worker(
      test_file: "passing_tests.rb",
      run_id: run_id,
      arguments: { "--key-ttl" => "300" },
    ).value
    assert_worker_successful(worker)

    keys = run_keys(run_id)
    refute_empty(keys)

    keys.each do |key|
      ttl = @redis.ttl(key)

      assert_operator(ttl, :>, 0, "#{key} has no expiry")
      assert_operator(ttl, :<=, 300, "#{key} did not use the configured TTL (TTL #{ttl})")
    end
  end

  private

  def run_keys(run_id)
    @redis.keys("minitest/#{run_id}/*")
  end
end
