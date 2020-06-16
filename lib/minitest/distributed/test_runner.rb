# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    class TestRunner
      extend T::Sig

      sig { returns(T::Hash[Symbol, T.untyped]) }
      attr_reader :options

      sig { returns(Configuration) }
      attr_reader :configuration

      sig { returns(TestSelector) }
      attr_reader :test_selector

      sig { returns(Coordinators::CoordinatorInterface) }
      attr_reader :coordinator

      sig { params(options: T::Hash[Symbol, T.untyped]).void }
      def initialize(options)
        @options = options

        @configuration = T.let(@options[:distributed], Configuration)
        @coordinator = T.let(configuration.coordinator, Coordinators::CoordinatorInterface)
        @test_selector = T.let(TestSelector.new(options), TestSelector)
      end

      sig { params(reporter: AbstractReporter).void }
      def run(reporter)
        coordinator.produce(test_selector: test_selector)
        coordinator.consume(reporter: reporter)
      end
    end
  end
end
