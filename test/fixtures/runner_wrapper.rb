# typed: false
# frozen_string_literal: true

# Test runner wrapper for integration tests. Supports eager and lazy loading modes.

require "minitest/autorun"

fixture_file = ARGV.shift
raise "Usage: runner_wrapper.rb <fixture_file> [args...]" unless fixture_file

fixture_path = File.join(__dir__, fixture_file)
raise "Fixture not found: #{fixture_path}" unless File.exist?(fixture_path)

if ARGV.include?("--lazy-load")
  ENV["MINITEST_TEST_FILES"] = fixture_path
else
  require fixture_path
end
