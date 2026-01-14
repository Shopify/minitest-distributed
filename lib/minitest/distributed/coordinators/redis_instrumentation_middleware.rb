# typed: strict
# frozen_string_literal: true

require "redis"

module Minitest
  module Distributed
    module Coordinators
      # Redis middleware that logs all Redis commands to a file for debugging.
      module RedisInstrumentationMiddleware
        extend T::Sig

        sig { params(command: T::Array[T.untyped], redis_config: T.untyped).returns(T.untyped) }
        def call(command, redis_config)
          log_file = redis_config.custom[:log_file]
          log_file.puts("EXEC: #{command.inspect}")
          result = super
          log_file.puts("RESULT: #{result.inspect}")
          result
        rescue => e
          log_file.puts("ERROR: #{e.class}")
          raise
        end

        sig { params(commands: T::Array[T.untyped], redis_config: T.untyped).returns(T.untyped) }
        def call_pipelined(commands, redis_config)
          log_file = redis_config.custom[:log_file]
          log_file.puts("EXEC PIPELINED: #{commands.inspect}")
          result = super
          log_file.puts("RESULT PIPELINED: #{result.inspect}")
          result
        rescue => e
          log_file.puts("ERROR PIPELINED: #{e.class}")
          raise
        end
      end
    end
  end
end
