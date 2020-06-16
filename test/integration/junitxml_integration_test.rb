# typed: true
# frozen_string_literal: true

require "test_helper"
require "rexml/document"

class JunitXMLIntegrationTest < IntegrationTest
  def test_generate_junitxml_report
    Tempfile.open("test_generate_junitxml_report") do |file|
      spawn_worker(test_file: "junit_reporter_test.rb", arguments: ["--junitxml", file.path, "--seed", "1"]).join

      doc = REXML::Document.new(file.read)

      test_case = doc.elements.to_a("//testcase")[0]
      assert_equal("test_crash", test_case.attributes["name"])
      assert_equal("JunitReporterTest", test_case.attributes["classname"])
      assert_equal("11", test_case.attributes["lineno"])
      test_suite = test_case.parent
      assert_equal("JunitReporterTest", test_suite.attributes["name"])
      assert_equal("2", test_suite.attributes["assertions"])
      assert_equal("2", test_suite.attributes["failures"])
      assert_equal("3", test_suite.attributes["tests"])

      test_case = doc.elements.to_a("//testcase")[1]
      assert_equal("test_pass", test_case.attributes["name"])
      assert_equal("JunitReporterTest", test_case.attributes["classname"])
      assert_equal("7", test_case.attributes["lineno"])

      test_case = doc.elements.to_a("//testcase")[2]
      assert_equal("test_fail", test_case.attributes["name"])
      assert_equal("JunitReporterTest", test_case.attributes["classname"])
      assert_equal("15", test_case.attributes["lineno"])
    end
  end
end
