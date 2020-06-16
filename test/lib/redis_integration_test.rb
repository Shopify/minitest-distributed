# typed: true
# frozen_string_literal: true

class RedisIntegrationTest < IntegrationTest
  def setup
    setup_redis
  end

  def teardown
    teardown_redis
  end

  protected

  REDIS_MONITOR_REGEXP = %r{
    (?<timestamp>\d+\.\d+)\s
    \[
      (?<database>\d+)\s
      (?<client>lua|\[.*\]:\d+|(\d+\.){3}\d+\:\d+)
    \]\s
    \"(?<command>\w+)\"
    (?<arguments>.*)
  }x
  private_constant :REDIS_MONITOR_REGEXP

  def setup_redis
    # We call FLUSHDB to reset our Redis DB to a known state before every test.
    # This can cause issues if we run these tests using a Redis queue with
    # multiple workers itself (very meta), because we end up resetting Redis
    # while another run is being coordinated using the same database.
    #
    # For running these tests, we need to use a Redis database that is:
    #   1) Not the coordinator for this build (we assume redis://localhost/0)
    #   2) Not the DB in use by any of the other workers.
    #
    # TODO: ensure that every worker uses a different redis in a better way.
    @redis_uri = "#{ENV.fetch("REDIS_URL", "redis://0.0.0.0:22220")}/#{Kernel.rand(1...16)}"
    @redis = Redis.new(url: @redis_uri)
    @redis.flushdb

    if ENV.key?("MONITOR_REDIS")
      @command_counts = Hash.new(0)
      @monitor_thread = Thread.new do
        @redis.monitor do |command|
          $stderr.puts command if ENV.key?("DEBUG")
          if (match_info = command.match(REDIS_MONITOR_REGEXP))
            @command_counts[T.must(match_info[:command]).upcase] += 1
          else
            $stderr.puts command
          end
        end
      end
    end
  end

  def teardown_redis
    if ENV.key?("MONITOR_REDIS")
      @monitor_thread.kill
      @redis.quit

      @command_counts.sort.each do |command, count|
        $stderr.puts format("%-15s %10dx", command, count)
      end
    end
  end

  def combined_results(run_id:, max_failures: nil)
    config = Minitest::Distributed::Configuration.new(
      coordinator_uri: URI(@redis_uri),
      run_id: run_id,
      max_failures: max_failures,
    )

    config.coordinator.combined_results
  end

  def spawn_redis_workers(test_file:, run_id:, count:, timeout: 10, arguments: {}, env: {})
    count.times.map do |index|
      spawn_redis_worker(
        test_file: test_file,
        run_id: run_id,
        timeout: timeout,
        arguments: arguments,
        env: env.merge("WORKER_INDEX" => index.to_s),
      )
    end
  end

  def spawn_redis_worker(test_file:, run_id:, worker_id: SecureRandom.uuid, arguments: {}, timeout: 10, env: {})
    spawn_worker(
      test_file: test_file,
      run_id: run_id,
      worker_id: worker_id,
      arguments: {
        "--test-timeout" => "1",
        "--test-batch-size" => "5",
      }.merge(arguments),
      timeout: timeout,
      env: env.merge("MINITEST_COORDINATOR" => @redis_uri),
    )
  end
end
