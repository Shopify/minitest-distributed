# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    module Filters
      class ExcludeFilter
        extend T::Sig
        include FilterInterface

        sig { returns(T.any(String, Regexp)) }
        attr_reader :filter

        sig { params(filter: T.any(String, Regexp)).void }
        def initialize(filter)
          @filter = filter
          if filter.is_a?(String) && (match_info = filter.match(%r%/(.*)/%))
            @filter = Regexp.new(T.must(match_info[1]))
          end
        end

        sig { override.params(runnable: Minitest::Runnable).returns(T::Array[Runnable]) }
        def call(runnable)
          # rubocop:disable Style/CaseEquality
          if filter === runnable.name || filter === DefinedRunnable.identifier(runnable)
            []
          else
            [runnable]
          end
          # rubocop:enable Style/CaseEquality
        end
      end
    end
  end
end
