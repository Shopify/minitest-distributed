# typed: strict

module Minitest
  class Runnable
    def self.run_one_method(klass, method_name, reporter); end
    def self.runnables; end
    def self.runnable_methods; end

    def initialize(method_name); end

    def name; end
    def time; end
    def time=(duration); end
    def failures; end
    def failures=(failures); end
    def assertions; end
    def assertions=(assertions); end
    def source_location; end
    def source_location=(value); end
    def klass; end
    def klass=(value); end
  end

  class Test < Runnable
    include Minitest::Assertions
  end

  class Result < Runnable
    sig { returns(String) }
    def name; end

    sig { returns(String) }
    def klass; end

    sig { returns(String) }
    def class_name; end

    sig { returns(T.nilable(Minitest::Assertion)) }
    def failure; end

    sig { returns(T::Boolean) }
    def error?; end

    sig { returns(T::Boolean) }
    def skipped?; end

    sig { returns(T::Boolean) }
    def passed?; end

    sig { returns(Integer) }
    def assertions; end

    sig { params(runnable: Runnable).returns(T.attached_class) }
    def self.from(runnable); end
  end

  class Assertion < Exception
    sig { returns(String) }
    def result_label; end

    sig { returns(String) }
    def result_code; end
  end

  class Skip < Assertion
  end

  class UnexpectedError < Assertion
    sig { params(error: Exception).void }
    def initialize(error); end

    sig { returns(Exception) }
    def error; end
  end

  class AbstractReporter
    sig { void }
    def start; end

    sig { params(runnable: T.class_of(Runnable), method_name: String).void }
    def prerecord(runnable, method_name); end

    sig { params(result: Minitest::Result).void }
    def record(result); end

    sig { void }
    def report; end

    sig { returns(T::Boolean) }
    def passed?; end
  end

  class Reporter < AbstractReporter
    sig { params(io: IO, options: T::Hash[Symbol, T.untyped]).void }
    def initialize(io, options); end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def options; end

    sig { returns(IO) }
    def io; end
  end

  class StatisticsReporter < Reporter
  end

  class SummaryReporter < StatisticsReporter
  end

  class ProgressReporter < Reporter
  end

  class CompositeReporter < AbstractReporter
    sig { params(reporter: AbstractReporter).returns(T.self_type) }
    def <<(reporter); end

    sig { returns(T::Array[AbstractReporter]) }
    def reporters; end
  end

  sig { returns(CompositeReporter) }
  def self.reporter; end

  sig { void }
  def self.autorun; end

  sig { returns(Integer) }
  def self.seed; end

  sig { params(args: T::Array[String]).returns(T::Boolean) }
  def self.run(args = []); end

  sig { params(klass: T.class_of(Runnable), method_name: String).returns(Minitest::Result) }
  def self.run_one_method(klass, method_name); end

  sig { returns(Float) }
  def self.clock_time; end

  def self.backtrace_filter; end
  def self.backtrace_filter=(filter); end
end

module Minitest::Assertions
  extend T::Sig

  sig { params(msg: T.nilable(String)).returns(TrueClass) }
  def pass(msg = nil); end

  sig { params(msg: T.nilable(String)).returns(FalseClass) }
  def flunk(msg = nil); end

  sig { params(test: T.untyped, msg: T.nilable(String)).returns(TrueClass) }
  def assert(test, msg = nil); end

  sig do
    params(
      exp: BasicObject,
      msg: T.nilable(String)
    ).returns(TrueClass)
  end
  def assert_empty(exp, msg = nil); end

  sig do
    params(
      exp: BasicObject,
      act: BasicObject,
      msg: T.nilable(String)
    ).returns(TrueClass)
  end
  def assert_equal(exp, act, msg = nil); end

  sig do
    params(
      collection: T::Enumerable[T.untyped],
      obj: BasicObject,
      msg: T.nilable(String)
    ).returns(TrueClass)
  end
  def assert_includes(collection, obj, msg = nil); end

  sig do
    params(
      obj: BasicObject,
      msg: T.nilable(String)
    ).returns(TrueClass)
  end
  def assert_nil(obj, msg = nil); end

  sig do
    params(
      exp: T.untyped
    ).returns(TrueClass)
  end
  def assert_raises(*exp); end

  sig do
    params(
      obj: BasicObject,
      predicate: Symbol,
      msg: T.nilable(String)
    ).returns(TrueClass)
  end
  def assert_predicate(obj, predicate, msg = nil); end

  sig do
    params(
      value: BasicObject,
      operator: Symbol,
      comparison: BasicObject,
      msg: T.nilable(String)
    ).returns(TrueClass)
  end
  def assert_operator(value, operator, comparison, msg = nil); end

  sig { params(test: T.untyped, msg: T.nilable(String)).returns(TrueClass) }
  def refute(test, msg = nil); end

  sig do
    params(
      exp: BasicObject,
      msg: T.nilable(String)
    ).returns(TrueClass)
  end
  def refute_empty(exp, msg = nil); end

  sig do
    params(
      exp: BasicObject,
      act: BasicObject,
      msg: T.nilable(String)
    ).returns(TrueClass)
  end
  def refute_equal(exp, act, msg = nil); end

  sig do
    params(
      collection: T::Enumerable[T.untyped],
      obj: BasicObject,
      msg: T.nilable(String)
    ).returns(TrueClass)
  end
  def refute_includes(collection, obj, msg = nil); end

  sig do
    params(
      obj: BasicObject,
      msg: T.nilable(String)
    ).returns(TrueClass)
  end
  def refute_nil(obj, msg = nil); end

  sig do
    params(
      obj: BasicObject,
      predicate: Symbol,
      msg: T.nilable(String)
    ).returns(TrueClass)
  end
  def refute_predicate(obj, predicate, msg = nil); end
end
