# typed: strict
# frozen_string_literal: true

require "uri"
require "securerandom"

module Minitest
  module Distributed
    class Configuration < T::Struct
      DEFAULT_BATCH_SIZE = 10
      DEFAULT_MAX_ATTEMPTS = 1
      DEFAULT_TEST_TIMEOUT_SECONDS = 30.0 # seconds

      class << self
        extend T::Sig

        sig { params(env: T::Hash[String, T.nilable(String)]).returns(T.attached_class) }
        def from_env(env = ENV.to_h)
          new(
            coordinator_uri: URI(env["MINITEST_COORDINATOR"] || "memory:"),
            run_id: env["MINITEST_RUN_ID"] || SecureRandom.uuid,
            worker_id: env["MINITEST_WORKER_ID"] || SecureRandom.uuid,
            test_timeout_seconds: Float(env["MINITEST_TEST_TIMEOUT_SECONDS"] || DEFAULT_TEST_TIMEOUT_SECONDS),
            test_batch_size: Integer(env["MINITEST_TEST_BATCH_SIZE"] || DEFAULT_BATCH_SIZE),
            max_attempts: Integer(env["MINITEST_MAX_ATTEMPTS"] || DEFAULT_MAX_ATTEMPTS),
            max_failures: (max_failures_env = env["MINITEST_MAX_FAILURES"]) ? Integer(max_failures_env) : nil,
          )
        end

        sig { params(opts: OptionParser, options: T::Hash[Symbol, T.untyped]).returns(T.attached_class) }
        def from_command_line_options(opts, options)
          configuration = from_env
          configuration.progress = options[:io].tty?

          opts.on("--coordinator=URI", "The URI pointing to the coordinator") do |uri|
            configuration.coordinator_uri = URI.parse(uri)
          end

          opts.on("--test-timeout=TIMEOUT", "The maximum run time for a single test in seconds") do |timeout|
            configuration.test_timeout_seconds = Float(timeout)
          end

          opts.on("--max-attempts=ATTEMPTS", "The maximum number of attempts to run a test") do |attempts|
            configuration.max_attempts = Integer(attempts)
          end

          opts.on("--test-batch-size=NUMBER", "The number of tests to process per batch") do |batch_size|
            configuration.test_batch_size = Integer(batch_size)
          end

          opts.on("--max-failures=FAILURES", "The maximum allowed failure before aborting a run") do |failures|
            configuration.max_failures = Integer(failures)
          end

          opts.on("--run-id=ID", "The ID for this run shared between coordinated workers") do |id|
            configuration.run_id = id
          end

          opts.on("--worker-id=ID", "The unique ID for this worker") do |id|
            configuration.worker_id = id
          end

          opts.on(
            "--[no-]retry-failures", "Retry failed and errored tests from a previous run attempt " \
              "with the same run ID (default: enabled)"
          ) do |enabled|
            configuration.retry_failures = enabled
          end

          opts.on("--[no-]progress", "Show progress during the test run") do |enabled|
            configuration.progress = enabled
          end

          opts.on("--exclude-file=FILE_PATH", "Specify a file of tests to be excluded from running") do |file_path|
            configuration.exclude_file = file_path
          end

          opts.on("--include-file=FILE_PATH", "Specify a file of tests to be included in the test run") do |file_path|
            configuration.include_file = file_path
          end

          opts.on("--[no-]shuffle-suites", "Shuffle test suites as well") do |enabled|
            configuration.shuffle_suites = enabled
          end

          configuration
        end
      end

      extend T::Sig

      # standard minitest options don't need to be specified
      prop :coordinator_uri, URI::Generic, default: URI("memory:")
      prop :run_id, String, factory: -> { SecureRandom.uuid }
      prop :worker_id, String, factory: -> { SecureRandom.uuid }
      prop :test_timeout_seconds, Float, default: DEFAULT_TEST_TIMEOUT_SECONDS
      prop :test_batch_size, Integer, default: DEFAULT_BATCH_SIZE
      prop :max_attempts, Integer, default: DEFAULT_MAX_ATTEMPTS
      prop :max_failures, T.nilable(Integer)
      prop :retry_failures, T::Boolean, default: true
      prop :progress, T::Boolean, default: false
      prop :exclude_file, T.nilable(String)
      prop :include_file, T.nilable(String)
      prop :shuffle_suites, T::Boolean, default: true

      sig { returns(Coordinators::CoordinatorInterface) }
      def coordinator
        @coordinator ||= T.let(
          case coordinator_uri.scheme
          when "redis"
            Coordinators::RedisCoordinator.new(configuration: self)
          when "memory"
            Coordinators::MemoryCoordinator.new(configuration: self)
          else
            raise NotImplementedError, "Unknown coordinator implementation: #{coordinator_uri.scheme}"
          end,
          T.nilable(Coordinators::CoordinatorInterface),
        )
      end
    end
  end
end
