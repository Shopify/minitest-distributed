# typed: strict
# frozen_string_literal: true

require "rexml/document"
require "fileutils"

module Minitest
  module Distributed
    module Reporters
      # Reporter that generates a JUnit XML report of the results it is presented.
      #
      # The JUnitXML schema is not very well standardized, and many implementations deviate
      # from the schema (see https://www.ibm.com/support/knowledgecenter/SSQ2R2_14.2.0/com.ibm.rsar.analysis.codereview.cobol.doc/topics/cac_useresults_junit.html).
      #
      # This JunitXML importer embraces this flexibility, and extends the format with some additional
      # information that we can use to create more meaningful annotations. For instance, the information
      # can be use to set annotations on your build system or for annotations using the GitHub checks API.
      #
      # For the implementation, we use REXML to prevent the need of additional dependencies on this gem.
      # We also use XML 1.1, which allows more characters to be valid. We are primarily interested in
      # this so \e is an allowed character, which is used for ANSI color coding.
      class JUnitXMLReporter < Minitest::Reporter
        extend T::Sig

        sig { returns(T::Hash[String, T::Array[Minitest::Result]]) }
        attr_reader :results

        sig { params(io: IO, options: T::Hash[Symbol, T.untyped]).void }
        def initialize(io, options)
          super
          @report_path = T.let(options.fetch(:junitxml), String)
          @results = T.let(Hash.new { |hash, key| hash[key] = [] }, T::Hash[String, T::Array[Minitest::Result]])
        end

        sig { override.params(result: Minitest::Result).void }
        def record(result)
          case (result_type = ResultType.of(result))
          when ResultType::Passed, ResultType::Failed, ResultType::Error
            T.must(results[result.klass]) << result
          when ResultType::Skipped, ResultType::Requeued, ResultType::Discarded
            # We will not include skipped, requeued, and discarded tests in JUnitXML reports,
            # because they will not fail builds, but also didn't pass.
          else
            T.absurd(result_type)
          end
        end

        sig { override.void }
        def report
          FileUtils.mkdir_p(File.dirname(@report_path))
          File.open(@report_path, "w+") do |file|
            format_document(generate_document, file)
          end
        end

        sig { returns(REXML::Document) }
        def generate_document
          doc = REXML::Document.new(nil, prologue_quote: :quote, attribute_quote: :quote)
          doc << REXML::XMLDecl.new("1.1", "utf-8")

          testsuites = doc.add_element("testsuites")
          results.each do |suite, tests|
            add_tests_to(testsuites, suite, tests)
          end
          doc
        end

        sig { params(doc: REXML::Document, io: IO).void }
        def format_document(doc, io)
          formatter = REXML::Formatters::Pretty.new
          formatter.write(doc, io)
          io << "\n"
        end

        private

        sig { params(testsuites: REXML::Element, suite: String, results: T::Array[Minitest::Result]).void }
        def add_tests_to(testsuites, suite, results)
          # TODO: make path relative to project root
          relative_path = T.must(results.first).source_location.first

          testsuite = testsuites.add_element(
            "testsuite",
            { "name" => suite, "filepath" => relative_path }.merge(aggregate_suite_results(results)),
          )

          results.each do |test|
            attributes = {
              "name" => test.name,
              "classname" => suite,
              "assertions" => test.assertions,
              "time" => test.time,
              # 'run-command' => ... # TODO
            }
            lineno = test.source_location.last
            attributes["lineno"] = lineno if lineno != -1

            testcase_tag = testsuite.add_element("testcase", attributes)
            add_failure_tag_if_needed(testcase_tag, test)
          end
        end

        sig { params(testcase: REXML::Element, result: Minitest::Result).void }
        def add_failure_tag_if_needed(testcase, result)
          case (result_type = ResultType.of(result))
          when ResultType::Passed, ResultType::Skipped, ResultType::Requeued, ResultType::Discarded
            # noop
          when ResultType::Error, ResultType::Failed
            failure = T.must(result.failure)
            failure_tag = testcase.add_element(
              "failure",
              "type" => result_type.serialize,
              "message" => truncate_message(failure.message),
            )
            failure_tag.add_text(REXML::CData.new(result.to_s))
          else
            T.absurd(result_type)
          end
        end

        sig { params(message: String).returns(String) }
        def truncate_message(message)
          T.must(message.lines.first).chomp.gsub(/\e\[[^m]+m/, "").gsub(/[\x00-\x1F\x7F]/, "")
        end

        sig { params(results: T::Array[Minitest::Result]).returns(T::Hash[String, Numeric]) }
        def aggregate_suite_results(results)
          aggregate = Hash.new(0)
          results.each do |result|
            aggregate["assertions"] += result.assertions
            aggregate["failures"] += 1 if failure?(ResultType.of(result))
            aggregate["tests"] += 1
            aggregate["time"] += result.time
          end
          aggregate
        end

        sig { params(result_type: ResultType).returns(T::Boolean) }
        def failure?(result_type)
          case result_type
          when ResultType::Failed, ResultType::Error
            true
          when ResultType::Passed, ResultType::Skipped, ResultType::Discarded, ResultType::Requeued
            false
          else
            T.absurd(result_type)
          end
        end
      end
    end
  end
end
