# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    module Coordinators
      module CoordinatorInterface
        extend T::Sig
        extend T::Helpers
        interface!

        sig { abstract.params(reporter: Minitest::CompositeReporter, options: T::Hash[Symbol, T.untyped]).void }
        def register_reporters(reporter:, options:); end

        sig { abstract.returns(ResultAggregate) }
        def local_results; end

        sig { abstract.returns(ResultAggregate) }
        def combined_results; end

        sig { abstract.returns(T::Boolean) }
        def aborted?; end

        sig { abstract.params(test_selector: TestSelector).void }
        def produce(test_selector:); end

        sig { abstract.params(reporter: Minitest::AbstractReporter).void }
        def consume(reporter:); end
      end
    end
  end
end
