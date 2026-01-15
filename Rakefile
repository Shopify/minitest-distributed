# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.warning = false
  t.test_files = FileList["test/integration/redis_timeout_discard_hang_test.rb"] -
    FileList["test/fixtures/**/*_test.rb"] - FileList["test/lib/**/*_test.rb"]
end

task(default: :test)
