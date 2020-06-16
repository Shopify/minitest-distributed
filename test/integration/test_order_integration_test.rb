# typed: true
# frozen_string_literal: true

require "test_helper"
require "rexml/document"

class TestOrderIntegrationTest < IntegrationTest
  def test_generate_test_order_file
    Tempfile.open("test_generate_test_order_file") do |file|
      spawn_worker(test_file: "junit_reporter_test.rb", arguments: ["--test_order", file.path, "--seed", "1"]).join

      assert_equal(<<~FILE, file.read)
        JunitReporterTest#test_crash
        JunitReporterTest#test_pass
        JunitReporterTest#test_fail
      FILE
    end
  end
end
