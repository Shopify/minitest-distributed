# typed: strict
# frozen_string_literal: true

require "io/console"

module Minitest
  module Distributed
    module Reporters
      class DistributedPogressReporter < Minitest::Reporter
        extend T::Sig

        sig { returns(Coordinators::CoordinatorInterface) }
        attr_reader :coordinator

        sig { params(io: IO, options: T::Hash[Symbol, T.untyped]).void }
        def initialize(io, options)
          super
          if io.tty?
            io.sync = true
          end
          @coordinator = T.let(options[:distributed].coordinator, Coordinators::CoordinatorInterface)
          @window_line_width = T.let(nil, T.nilable(Integer))
          @show_progress = T.let(options[:distributed].progress, T::Boolean)
        end

        sig { override.void }
        def start
          Signal.trap("WINCH") { @window_line_width = nil }
          super
        end

        # NOTE: due to batching and parallel tests, we have no guarantee that `prerecord`
        # and `record` will be called in succession for the same test without calls to
        # either method being interjected for other tests.
        #
        # As a result we have no idea what will be on the last line of the console.
        # We always clear the full line before printing output.

        sig { override.params(klass: T.class_of(Runnable), name: String).void }
        def prerecord(klass, name)
          if show_progress?
            clear_current_line
            io.print("[#{results.acks}/#{results.size}] #{klass}##{name}".slice(0...window_line_width))
          end
        end

        sig { override.params(result: Minitest::Result).void }
        def record(result)
          clear_current_line if show_progress?

          case (result_type = ResultType.of(result))
          when ResultType::Passed
            # TODO: warn for tests that are slower than the test timeout.
          when ResultType::Skipped, ResultType::Discarded
            io.puts("#{result}\n") if options[:verbose]
          when ResultType::Error, ResultType::Failed, ResultType::Requeued
            io.puts("#{result}\n")
          else
            T.absurd(result_type)
          end
        end

        sig { override.void }
        def report
          clear_current_line if show_progress?
        end

        private

        sig { returns(T::Boolean) }
        def show_progress?
          @show_progress
        end

        sig { void }
        def clear_current_line
          io.print("\r" + (" " * window_line_width) + "\r")
        end

        sig { returns(Integer) }
        def window_line_width
          @window_line_width ||= begin
            _height, width = io.winsize
            width > 0 ? width : 80
          rescue Errno::ENOTTY
            80
          end
        end

        sig { returns(ResultAggregate) }
        def results
          coordinator.combined_results
        end
      end
    end
  end
end
