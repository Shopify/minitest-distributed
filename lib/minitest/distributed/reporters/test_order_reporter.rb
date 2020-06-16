# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    module Reporters
      class TestOrderReporter < Minitest::Reporter
        extend T::Sig

        sig { params(io: IO, options: T::Hash[Symbol, T.untyped]).void }
        def initialize(io, options)
          super
          @path = T.let(options.fetch(:test_order_file), String)
          @file = T.let(nil, T.nilable(File))
        end

        sig { void }
        def start
          @file = File.open(@path, "w+")
          super
        end

        sig { override.params(klass: T::Class[T.anything], name: String).void }
        def prerecord(klass, name)
          T.must(@file).puts("#{klass}##{name}")
          T.must(@file).flush
        end

        sig { override.void }
        def report
          T.must(@file).close
        end
      end
    end
  end
end
