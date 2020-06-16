# typed: strict
# frozen_string_literal: true

require "pathname"

module Minitest
  module Distributed
    class TestSelector
      extend T::Sig

      sig { returns(T::Hash[Symbol, T.untyped]) }
      attr_reader :options

      sig { returns(T::Array[Filters::FilterInterface]) }
      attr_reader :filters

      sig { params(options: T::Hash[Symbol, T.untyped]).void }
      def initialize(options)
        @options = options

        @filters = T.let([], T::Array[Filters::FilterInterface])
        initialize_filters
      end

      sig { void }
      def initialize_filters
        @filters << Filters::IncludeFilter.new(options[:filter]) if options[:filter]
        @filters << Filters::ExcludeFilter.new(options[:exclude]) if options[:exclude]

        exclude_file = options[:distributed].exclude_file
        @filters << Filters::ExcludeFileFilter.new(Pathname.new(exclude_file)) if exclude_file

        include_file = options[:distributed].include_file
        @filters << Filters::IncludeFileFilter.new(Pathname.new(include_file)) if include_file
      end

      sig { returns(T::Array[Minitest::Runnable]) }
      def discover_tests
        runnables.flat_map do |runnable|
          runnable.runnable_methods.map { |method_name| runnable.new(method_name) }
        end
      end

      sig { returns(T::Array[T.class_of(Minitest::Runnable)]) }
      def runnables
        if options[:distributed].shuffle_suites
          srand(Minitest.seed)
          Minitest::Runnable.runnables.shuffle
        else
          Minitest::Runnable.runnables
        end
      end

      sig { params(tests: T::Array[Minitest::Runnable]).returns(T::Array[Minitest::Runnable]) }
      def select_tests(tests)
        return tests if filters.empty?

        tests.flat_map do |runnable_method|
          filters.flat_map do |filter|
            filter.call(runnable_method)
          end
        end.compact
      end

      sig { returns(T::Array[Minitest::Runnable]) }
      def tests
        select_tests(discover_tests)
      end
    end
  end
end
