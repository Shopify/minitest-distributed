# typed: true
# frozen_string_literal: true

require "test_helper"

class RedisCommitReceiptIntegrationTest < RedisIntegrationTest
  def setup
    super
    @configuration = Minitest::Distributed::Configuration.new(
      coordinator_uri: URI(@redis_uri), run_id: name, worker_id: "worker",
    )
    @coordinator = @configuration.coordinator
    fixture = T.let(Class.new(Minitest::Test), T.class_of(Minitest::Test))
    fixture.send(:define_method, :test_passes) { assert(true) }
    T.unsafe(Object).const_set(:CommitReceiptFixture, fixture)
    selector = Minitest::Distributed::TestSelector.allocate
    selector.define_singleton_method(:tests) { [fixture.new(:test_passes)] }
    @coordinator.produce(test_selector: selector)
    claim = T.unsafe(@coordinator).send(:claim_fresh_runnables, block: 1).fetch(0)
    @results = [[claim, claim.instantiate_runnable.run]]
  end

  def teardown
    T.unsafe(Object).send(:remove_const, :CommitReceiptFixture)
    super
  end

  def test_replayed_batch_returns_original_receipt_without_counting_twice
    original = @coordinator.method(:execute_script)
    replies = []
    @coordinator.define_singleton_method(:execute_script) do |**arguments|
      response = original.call(**arguments)
      if arguments.fetch(:script_name) == :commit_results
        replies << response
        replies << original.call(**arguments)
      end
      response
    end

    committed = T.unsafe(@coordinator).send(:commit_results, @results)

    assert_predicate(committed.first.commit, :success?)
    assert_equal(replies.first, replies.last)
    assert_equal(["1", "1", "1", "0", "1"], stats)
  end

  def test_receipt_survives_stream_cleanup
    request = committed_request
    T.unsafe(@coordinator).send(:cleanup)

    assert_equal(request.fetch(:reply), replay(request))
    assert_equal(["1", "1", "1", "0", "1"], stats)
    assert_operator(@redis.ttl(request.fetch(:keys).last), :>, 0)
  end

  def test_receipt_rejects_a_different_payload
    request = committed_request
    request.fetch(:argv)[-2] = 2

    error = T.unsafe(assert_raises(Redis::CommandError) { replay(request) })

    assert_includes(error.message, "commit receipt payload mismatch")
    assert_equal(["1", "1", "1", "0", "1"], stats)
  end

  def test_receipt_cannot_cross_attempt_generations
    request = committed_request
    @redis.set("minitest/v3/#{name}/attempt_generation", "replacement")

    error = T.unsafe(assert_raises(Redis::CommandError) { replay(request) })

    assert_includes(error.message, "STALEATTEMPT")
    assert_equal(["1", "1", "1", "0", "1"], stats)
  end

  def test_receipt_does_not_hide_lost_authoritative_state
    request = committed_request
    @redis.del("minitest/v3/#{name}/acks")

    error = T.unsafe(assert_raises(Redis::CommandError) { replay(request) })

    assert_includes(error.message, "COORDINATORSTATE missing")
    assert_nil(@redis.get("minitest/v3/#{name}/acks"))
  end

  def test_replayed_failure_does_not_duplicate_the_failure_list
    assert_replayed_outcome("failed", "failures", "failed")
  end

  def test_replayed_error_does_not_duplicate_the_error_list
    assert_replayed_outcome("error", "errors", "error")
  end

  def test_replayed_skip_does_not_duplicate_the_skipped_list
    assert_replayed_outcome("skipped", "skips", "skipped")
  end

  def test_replayed_discard_is_only_counted_once
    assert_replayed_outcome("discarded", "discards")
  end

  def test_replayed_requeue_is_only_counted_once
    assert_replayed_outcome("requeued", "requeues")
    assert_equal("0", @redis.get("minitest/v3/#{name}/acks"))
    assert_equal(1, @redis.scard("minitest/v3/#{name}/retry_set"))
  end

  def test_lost_commit_response_is_recovered_without_reapplying_the_batch
    original = @coordinator.method(:execute_script)
    calls = 0
    @coordinator.define_singleton_method(:execute_script) do |**arguments|
      response = original.call(**arguments)
      if arguments.fetch(:script_name) == :commit_results
        calls += 1
        raise Redis::TimeoutError, "response lost after execution" if calls == 1
      end
      response
    end

    committed = T.unsafe(@coordinator).send(:commit_results, @results)

    assert_predicate(committed.first.commit, :success?)
    assert_equal(2, calls)
    assert_equal(["1", "1", "1", "0", "1"], stats)
  end

  def test_missing_receipt_after_connection_failure_fails_closed
    original = @coordinator.method(:execute_script)
    calls = 0
    @coordinator.define_singleton_method(:execute_script) do |**arguments|
      if arguments.fetch(:script_name) == :commit_results
        calls += 1
        raise Redis::ConnectionError, "connection lost before execution" if calls == 1
      end
      original.call(**arguments)
    end

    error = T.unsafe(assert_raises(Redis::CommandError) do
      T.unsafe(@coordinator).send(:commit_results, @results)
    end)

    assert_includes(error.message, "missing commit receipt during recovery")
    assert_equal(2, calls)
    assert_equal(["0", "0", "0", "0", "0"], stats)
  end

  def test_recovery_is_bounded_when_redis_stays_unavailable
    calls = 0
    @coordinator.define_singleton_method(:execute_script) do |**_arguments|
      calls += 1
      raise Redis::TimeoutError, "still unavailable"
    end

    assert_raises(Redis::TimeoutError) do
      T.unsafe(@coordinator).send(:commit_results, @results)
    end

    assert_equal(3, calls)
    assert_equal(["0", "0", "0", "0", "0"], stats)
  end

  def test_expired_receipt_cannot_cause_a_recovery_to_count_twice
    request = committed_request
    @redis.pexpire(request.fetch(:keys).last, 1)
    sleep(0.02)
    request.fetch(:argv)[-1] = "recover"

    error = T.unsafe(assert_raises(Redis::CommandError) { replay(request) })

    assert_includes(error.message, "missing commit receipt during recovery")
    assert_equal(["1", "1", "1", "0", "1"], stats)
  end

  def test_receipt_preserves_large_assertion_counts_exactly
    @results.first.last.assertions = 1_234_567_890_123_456
    request = committed_request

    assert_equal(request.fetch(:reply), replay(request))
    assert_equal("1234567890123456", @redis.get("minitest/v3/#{name}/assertions"))
  end

  def test_missing_generation_prevents_receipt_recovery
    request = committed_request
    @redis.del("minitest/v3/#{name}/attempt_generation")

    error = T.unsafe(assert_raises(Redis::CommandError) { replay(request) })

    assert_includes(error.message, "COORDINATORSTATE missing")
    assert_equal(["1", "1", "1", "0", "1"], stats)
  end

  private

  def committed_request(outcome: "passed")
    original = @coordinator.method(:execute_script)
    request = {}
    @coordinator.define_singleton_method(:execute_script) do |**arguments|
      if arguments.fetch(:script_name) == :commit_results
        arguments.fetch(:argv)[5] = outcome
        request.merge!(arguments)
        request[:reply] = original.call(**arguments)
      else
        original.call(**arguments)
      end
    end
    T.unsafe(@coordinator).send(:commit_results, @results)
    @coordinator.define_singleton_method(:execute_script, original)
    request
  end

  def replay(request)
    T.unsafe(@coordinator).send(:execute_script, **request.reject { |key, _| key == :reply })
  end

  def assert_replayed_outcome(outcome, counter, list = nil)
    request = committed_request(outcome: outcome)
    assert_equal(request.fetch(:reply), replay(request))
    assert_equal(["1", "1", "1"], @redis.mget(*["runs", "assertions", counter].map { |stat| "minitest/v3/#{name}/#{stat}" }))
    assert_equal(["CommitReceiptFixture#test_passes"], @redis.lrange("minitest/v3/#{name}/#{list}_list", 0, -1)) if list
  end

  def stats
    @redis.mget(*["runs", "assertions", "passes", "discards", "acks"].map { |stat| "minitest/v3/#{name}/#{stat}" })
  end
end
