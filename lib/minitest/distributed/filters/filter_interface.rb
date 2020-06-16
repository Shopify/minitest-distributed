# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    module Filters
      # A filter proc is a callable object that changes the list of runnables that will
      # be executed during the test run. For every runnable, it should return an
      # array of runnables.
      #
      # - If it returns an empty array, the runnable will not be run.
      # - If it returns a single element array with the passed ion runnable to make no changes.
      # - It can return an array of enumerables to expand the number of runnables in this test run,
      #   We use this for grinding tests, for instance.
      module FilterInterface
        extend T::Sig
        extend T::Helpers
        interface!

        sig { abstract.params(runnable: Minitest::Runnable).returns(T::Array[Minitest::Runnable]) }
        def call(runnable); end
      end
    end
  end
end
