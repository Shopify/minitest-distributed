# typed: true
# frozen_string_literal: true

# Custom test loader for minitest-distributed lazy loading.
# Replaces Rake's default loader to defer test file loading when MINITEST_LAZY_LOAD=true.

require "rake/file_list"

lazy_load = ENV["MINITEST_LAZY_LOAD"] == "true"
test_files = []

argv = ARGV.select do |argument|
  case argument
  when /^-/
    true
  when /\*/
    Rake::FileList[argument].to_a.each do |file|
      path = File.expand_path(file)
      lazy_load ? test_files << path : require(path)
    end
    false
  else
    path = File.expand_path(argument)
    abort("\nFile does not exist: #{path}\n\n") unless File.exist?(path)
    lazy_load ? test_files << path : require(path)
    false
  end
end

if lazy_load && test_files.any?
  ENV["MINITEST_TEST_FILES"] = test_files.join(",")
end

ARGV.replace(argv)

# Trigger minitest since test files (which normally require minitest/autorun) weren't loaded
require "minitest/autorun" if lazy_load
