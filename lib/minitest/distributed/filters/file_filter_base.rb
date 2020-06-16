# typed: strict
# frozen_string_literal: true

module Minitest
  module Distributed
    module Filters
      class FileFilterBase
        extend T::Sig

        sig { returns(Pathname) }
        attr_reader :file

        sig { params(file: Pathname).void }
        def initialize(file)
          @file = file
          @tests = T.let(nil, T.nilable(T::Set[String]))
        end

        sig { returns(T::Set[String]) }
        def tests
          @tests ||= begin
            tests = File.readlines(@file, chomp: true)
            Set.new(tests)
          end
        end
      end
    end
  end
end
