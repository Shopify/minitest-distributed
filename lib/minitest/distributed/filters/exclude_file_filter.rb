# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    module Filters
      class ExcludeFileFilter < FileFilterBase
        extend T::Sig
        include FilterInterface

        sig { override.params(runnable: Minitest::Runnable).returns(T::Array[Runnable]) }
        def call(runnable)
          tests.include?(DefinedRunnable.identifier(runnable)) ? [] : [runnable]
        end
      end
    end
  end
end
