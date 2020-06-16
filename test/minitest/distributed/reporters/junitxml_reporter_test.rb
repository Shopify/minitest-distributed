# typed: true
# frozen_string_literal: true

require "test_helper"
require "minitest/distributed/reporters/junitxml_reporter"

module Minitest
  module Distributed
    module Reporters
      class JunitXMLReporterTest < Minitest::Test
        def test_generate_empty_report
          Tempfile.open("test_generate_empty_report") do |file|
            reporter = JUnitXMLReporter.new($stderr, junitxml: file.path)
            reporter.report

            assert_equal(<<~XML, file.read)
              <?xml version="1.1" encoding="UTF-8"?>
              <testsuites/>
            XML
          end
        end

        def test_generate_report_with_several_passing_tests
          Tempfile.open("test_generate_report_with_passing_tests") do |file|
            reporter = JUnitXMLReporter.new($stderr, junitxml: file.path)
            reporter.record(mock_pass(klass: "Foo", name: "test_foo_1", assertions: 4, time: 0.5))
            reporter.record(mock_pass(klass: "Foo", name: "test_foo_2", assertions: 2, time: 1.0))
            reporter.record(mock_pass(klass: "Bar", name: "test_bar_1", assertions: 4, time: 0.5))
            reporter.record(mock_pass(klass: "Bar", name: "test_bar_2", assertions: 3, time: 0.5))
            reporter.report

            assert_equal(<<~XML, file.read)
              <?xml version="1.1" encoding="UTF-8"?>
              <testsuites>
                <testsuite name="Foo" filepath="test/path/to/my_test.rb" assertions="6" tests="2" time="1.5">
                  <testcase name="test_foo_1" classname="Foo" assertions="4" time="0.5" lineno="123"/>
                  <testcase name="test_foo_2" classname="Foo" assertions="2" time="1.0" lineno="123"/>
                </testsuite>
                <testsuite name="Bar" filepath="test/path/to/my_test.rb" assertions="7" tests="2" time="1.0">
                  <testcase name="test_bar_1" classname="Bar" assertions="4" time="0.5" lineno="123"/>
                  <testcase name="test_bar_2" classname="Bar" assertions="3" time="0.5" lineno="123"/>
                </testsuite>
              </testsuites>
            XML
          end
        end

        def test_generate_report_does_not_incude_skipped_tests
          Tempfile.open("test_generate_report_does_not_incude_skipped_tests") do |file|
            reporter = JUnitXMLReporter.new($stderr, junitxml: file.path)
            reporter.record(mock_skip)
            reporter.report

            assert_equal(<<~XML, file.read)
              <?xml version="1.1" encoding="UTF-8"?>
              <testsuites/>
            XML
          end
        end

        def test_generate_report_with_error
          Tempfile.open("test_generate_report_with_error") do |file|
            reporter = JUnitXMLReporter.new($stderr, junitxml: file.path)
            reporter.record(mock_error)
            reporter.report

            assert_equal(<<~XML, file.read)
              <?xml version="1.1" encoding="UTF-8"?>
              <testsuites>
                <testsuite name="MyTest" filepath="test/path/to/my_test.rb" assertions="1" failures="1" tests="1" time="0.5">
                  <testcase name="test_foo" classname="MyTest" assertions="1" time="0.5" lineno="123">
                    <failure type="error" message="RuntimeError: unexpected">
                      <![CDATA[Error:
              MyTest#test_foo:
              RuntimeError: unexpected
                  /usr/lib/ruby/2.6.0/irb/workspace.rb:85:in `eval'
                  /usr/lib/ruby/2.6.0/irb/workspace.rb:85:in `evaluate'
                  /usr/bin/irb:23:in `<main>'
              ]]>
                    </failure>
                  </testcase>
                </testsuite>
              </testsuites>
            XML
          end
        end

        def test_generate_report_with_failure
          Tempfile.open("test_generate_report_with_failure") do |file|
            reporter = JUnitXMLReporter.new($stderr, junitxml: file.path)
            reporter.record(mock_failure)
            reporter.report

            assert_equal(<<~XML, file.read)
              <?xml version="1.1" encoding="UTF-8"?>
              <testsuites>
                <testsuite name="MyTest" filepath="test/path/to/my_test.rb" assertions="1" failures="1" tests="1" time="0.5">
                  <testcase name="test_foo" classname="MyTest" assertions="1" time="0.5" lineno="123">
                    <failure type="failed" message="Epic failure!">
                      <![CDATA[Failure:
              MyTest#test_foo [test/minitest/distributed/self_test.rb:123]:
              Epic failure!
              ]]>
                    </failure>
                  </testcase>
                </testsuite>
              </testsuites>
            XML
          end
        end

        private

        def mock_pass(klass: "MyTest", name: "test_foo", time: 0.5, assertions: 1)
          pass = Minitest::Result.new(name)
          pass.failures = []
          pass.klass = klass
          pass.source_location = ["test/path/to/my_test.rb", 123]
          pass.assertions = assertions
          pass.time = time

          pass
        end

        def mock_skip(klass: "MyTest", name: "test_foo", time: 0.1, message: "Skipped")
          assertion = Minitest::Skip.new(message)
          assertion.set_backtrace(mock_backtrace)

          skip = Minitest::Result.new(name)
          skip.failures = [assertion]
          skip.klass = klass
          skip.source_location = ["test/path/to/my_test.rb", 123]
          skip.assertions = 0
          skip.time = time

          skip
        end

        def mock_error(klass: "MyTest", name: "test_foo", time: 0.5, assertions: 1)
          exception = RuntimeError.new("unexpected")
          exception.set_backtrace([
            "/usr/lib/ruby/2.6.0/irb/workspace.rb:85:in `eval'",
            "/usr/lib/ruby/2.6.0/irb/workspace.rb:85:in `evaluate'",
            "/usr/bin/irb:23:in `<main>'",
          ])

          assertion = Minitest::UnexpectedError.new(exception)
          assertion.set_backtrace(mock_backtrace)

          error = Minitest::Result.new(name)
          error.failures = [assertion]
          error.klass = klass
          error.source_location = ["test/path/to/my_test.rb", 123]
          error.assertions = assertions
          error.time = time

          error
        end

        def mock_failure(klass: "MyTest", name: "test_foo", message: "Epic failure!", time: 0.5, assertions: 1)
          assertion = Minitest::Assertion.new(message)
          assertion.set_backtrace(mock_backtrace)

          failure = Minitest::Result.new(name)
          failure.failures = [assertion]
          failure.klass = klass
          failure.source_location = ["test/path/to/my_test.rb", 123]
          failure.assertions = assertions
          failure.time = time

          failure
        end

        def mock_backtrace
          @mock_backtrace ||= [
            "test/minitest/distributed/self_test.rb:123",
            "test/minitest/distributed/self_test.rb:345",
            "test/minitest/distributed/self_test.rb:567",
          ]
        end
      end
    end
  end
end
