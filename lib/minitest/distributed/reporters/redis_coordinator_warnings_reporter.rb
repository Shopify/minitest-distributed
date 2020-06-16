# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    module Reporters
      class RedisCoordinatorWarningsReporter < Minitest::Reporter
        extend T::Sig

        sig { override.void }
        def report
          warnings = [reclaim_timeout_warning, reclaim_failed_warning].compact
          warnings.each do |warning|
            io.puts(warning)
            io.puts
          end
        end

        private

        sig { returns(Configuration) }
        def configuration
          options[:distributed]
        end

        sig { returns(Coordinators::RedisCoordinator) }
        def redis_coordinator
          T.cast(configuration.coordinator, Coordinators::RedisCoordinator)
        end

        sig { returns(T.nilable(String)) }
        def reclaim_timeout_warning
          if redis_coordinator.reclaimed_timeout_tests.any?
            <<~WARNING
              WARNING: The following tests were reclaimed from another worker:
              #{redis_coordinator.reclaimed_timeout_tests.map { |test| "- #{test.identifier}" }.join("\n")}

              The original worker did not complete running these tests in #{configuration.test_timeout_seconds}s.
              This either means that the worker unexpectedly went away, or that the test is too slow.
            WARNING
          end
        end

        sig { returns(T.nilable(String)) }
        def reclaim_failed_warning
          if redis_coordinator.reclaimed_failed_tests.any?
            <<~WARNING
              WARNING: The following tests were reclaimed from another worker because they failed:
              #{redis_coordinator.reclaimed_failed_tests.map { |test| "- #{test.identifier}" }.join("\n")}
            WARNING
          end
        end
      end
    end
  end
end
