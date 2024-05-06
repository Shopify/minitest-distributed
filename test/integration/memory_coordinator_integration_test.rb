# typed: true
# frozen_string_literal: true

require "test_helper"
require "rexml/document"

class MemoryCoordinatorIntegrationTest < IntegrationTest
  def test_disable_distributed
    worker = spawn_worker(
      test_file: "no_tests.rb",
      run_id: "foo",
      worker_id: "bar",
      arguments: ["--seed", "12345", "--disable-distributed"],
    ).value

    assert_worker_successful(worker)
    assert_equal(<<~EOM, normalize_output(worker.stdout))
      Run options: --verbose --run-id foo --worker-id bar --enable-distributed --seed 12345 --disable-distributed

      # Running:

    EOM
  end

  def test_no_tests
    worker = spawn_worker(
      test_file: "no_tests.rb",
      run_id: "foo",
      worker_id: "bar",
      arguments: ["--seed", "12345"],
    ).value

    assert_worker_successful(worker)
    assert_equal(<<~EOM, normalize_output(worker.stdout))
      Run options: --verbose --run-id foo --worker-id bar --enable-distributed --seed 12345

      Results: 0 runs, 0 assertions, 0 passes, 0 failures, 0 errors (in 0.123s)
    EOM
  end

  def test_passing_tests
    runner = spawn_worker(test_file: "passing_tests.rb").value

    assert_worker_successful(runner)
    assert_output_includes(runner, "Results: 100 runs, 100 assertions, 100 passes, 0 failures, 0 errors")
  end

  def test_passing_tests_with_include_filter
    runner = spawn_worker(test_file: "passing_tests.rb", arguments: ["-n", "test_pass_1"]).value

    assert_worker_successful(runner)
    assert_output_includes(runner, "Results: 1 runs, 1 assertions, 1 passes, 0 failures, 0 errors")
  end

  def test_passing_tests_with_include_filter_that_matches_nothing
    runner = spawn_worker(test_file: "passing_tests.rb", arguments: ["-n", "test_foo"]).value

    assert_worker_successful(runner)
    assert_output_includes(runner, "Results: 0 runs, 0 assertions, 0 passes, 0 failures, 0 errors")
  end

  def test_failing_tests_with_single_attempt
    runner = spawn_worker(test_file: "failing_tests.rb", arguments: ["--max-attempts=1"]).value

    refute_worker_successful(runner)
    assert_output_includes(runner, "Results: 100 runs, 100 assertions, 99 passes, 1 failures, 0 errors")
  end

  def test_failing_tests_with_multiple_attempts
    runner = spawn_worker(test_file: "failing_tests.rb", arguments: ["--max-attempts=3"]).value

    refute_worker_successful(runner)
    assert_output_includes(runner, "Results: 102 runs, 102 assertions, 99 passes, 1 failures, 0 errors, 2 re-queued")
  end

  def test_failing_with_exclude_filter
    runner = spawn_worker(test_file: "failing_tests.rb", arguments: ["-e", "test_fail"]).value

    assert_worker_successful(runner)
    assert_output_includes(runner, "Results: 99 runs, 99 assertions, 99 passes, 0 failures, 0 errors")
  end

  def test_failing_with_exclude_filter_that_matches_nothing
    runner = spawn_worker(test_file: "failing_tests.rb", arguments: ["--max-attempts=1", "-e", "test_foo"]).value

    refute_worker_successful(runner)
    assert_output_includes(runner, "Results: 100 runs, 100 assertions, 99 passes, 1 failures, 0 errors")
  end

  def test_failing_with_exclude_filter_using_full_identifier
    runner = spawn_worker(test_file: "failing_tests.rb", arguments: ["-e", "FailingTests#test_fail"]).value

    assert_worker_successful(runner)
    assert_output_includes(runner, "Results: 99 runs, 99 assertions, 99 passes, 0 failures, 0 errors")
  end

  def test_only_tests_listed_in_the_include_file_filter_are_run
    Tempfile.open("test_failing_with_include_file_filter") do |f|
      content = <<~CONTENT
        FailingTests#test_pass_1
        FailingTests#test_pass_2
      CONTENT
      f.write(content)
      f.close

      runner = spawn_worker(test_file: "failing_tests.rb", arguments: ["--include-file", f.path]).value

      assert_worker_successful(runner)
      assert_output_includes(runner, "Results: 2 runs, 2 assertions, 2 passes, 0 failures, 0 errors")
    end
  end

  def test_tests_listed_in_the_exclude_file_filter_are_not_run
    Tempfile.open("test_failing_with_exclude_file_filter") do |f|
      content = <<~CONTENT
        FailingTests#test_fail
        FailingTests#test_pass_2
      CONTENT
      f.write(content)
      f.close

      runner = spawn_worker(test_file: "failing_tests.rb", arguments: ["--exclude-file", f.path]).value

      assert_worker_successful(runner)
      assert_output_includes(runner, "Results: 98 runs, 98 assertions, 98 passes, 0 failures, 0 errors")
    end
  end

  def test_failing_with_exclude_filter_using_regexp
    runner = spawn_worker(
      test_file: "failing_tests.rb",
      arguments: ["--max-attempts=1", "-e", "/test_pass_\\d+/"],
    ).value

    refute_worker_successful(runner)
    assert_output_includes(runner, "Results: 1 runs, 1 assertions, 0 passes, 1 failures, 0 errors")
  end

  def test_retry_flaky_test
    Tempfile.open("test_flaky_test_fails_with_only_one_attempt") do |f|
      worker = spawn_worker(
        test_file: "flaky_test.rb",
        arguments: ["--max-attempts=2"],
        env: { "FLAKY_TRACKER_FILE" => f.path },
      ).value

      assert_worker_successful(worker)
      assert_output_includes(worker, "Results: 101 runs, 101 assertions, 100 passes, 0 failures, 0 errors, 1 re-queued")
    end
  end

  def test_max_failures
    worker = spawn_worker(
      test_file: "only_failures.rb",
      arguments: ["--max-failures=10"],
    ).value

    refute_worker_successful(worker)
    assert_output_includes(worker, "Results: 10 runs, 10 assertions, 0 passes, 10 failures, 0 errors")
    assert_output_includes(worker, "The run was cut short after reaching the limit of 10 test failures.")
  end

  def test_shuffle_suites
    Tempfile.open("test_generate_junitxml_report") do |file|
      spawn_worker(
        test_file: "several_suites.rb",
        arguments: ["--shuffle-suites", "--seed", "1", "--junitxml", file.path],
      ).value

      doc = REXML::Document.new(file.read)
      suites = doc.elements.to_a("//testsuite")

      assert_equal("BSuite", suites[0].attributes["name"])
      assert_equal("ASuite", suites[1].attributes["name"])
    end
  end

  def test_no_shuffle_suites
    Tempfile.open("test_generate_junitxml_report") do |file|
      spawn_worker(
        test_file: "several_suites.rb",
        arguments: ["--no-shuffle-suites", "--junitxml", file.path],
      ).value

      doc = REXML::Document.new(file.read)
      suites = doc.elements.to_a("//testsuite")

      assert_equal("ASuite", suites[0].attributes["name"])
      assert_equal("BSuite", suites[1].attributes["name"])
    end
  end

  private

  def normalize_output(output)
    output.gsub(/\d+\.\d+/, "0.123")
  end
end
