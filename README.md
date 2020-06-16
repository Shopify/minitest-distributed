# minitest-distributed

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE.md)

[About this repo](#about-this-repo) | [Commands](#commands) | [How to use this repo](#how-to-use-this-repo) | [Contribute to this repo](#contribute-to-this-repo) | [License](#license)

## About this repo
**Introduction:**

`minitest-distributed` is a plugin for [minitest](https://github.com/seattlerb/minitest)
for executing tests on a distributed set of unreliable workers.

When a test suite grows large enough, it inevitable gets too slow to run on a
single machine to give timely feedback to developers. This plugins combats
this issue by distributing the full test suite to a set of workers. Every
worker is a consuming from a single queue, so the tests get evenly distributed
and all workers will finish around the same time. Redis is used as
coordinator, but when using this plugin without having access to Redis, it
will use an in-memory coordinator.

Using multiple (virtual) machines for a test run is an (additional) source of
flakiness. To combat flakiness, minitest-distributed implements resiliency
patterns, like re-running a test on a different worker on failure, and a
circuit breaker for misbehaving workers.

## Commands
**Distributed invocation**

To actually run tests with multiple workers, you have to point every worker to
a Redis coordinator, and use the same run identifier.

``` sh
ruby -Itest --coordinator=redis://localhost/1 --run-id=<BUILD_NUMBER> test/my_test.rb
```

We recommend using the build number or identifier form your CI system as run
identifier, but it will work with any value that is shared between all
workers. You can also set these values by setting the `MINITEST_COORDINATOR`
and `MINITEST_RUN_ID` environment variables, respectively.

If you are using a Rails project, the Rails test runner (`bin/rails test`)
will also support these command line arguments and environment variables.

If you are using a `Rake::TestTask` to invoke your test suite, you can set
these command line arguments using `options`:

``` ruby
Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.warning = false
  t.options = "--coordinator=redis://localhost/1 --run-id=<BUILD_NUMBER>"
  t.test_files = FileList["test/**/*_test.rb"]
end
```

**Worker retries**

Many CI systems offer the options to retry jobs that fail. When jobs are
retried that were previously part of a worker cluster, all the retried jobs
together will form a new cluster, and will only run the tests that failed
during the previous run attempt. This is to make it faster to re-run tests
that failed due to flakiness, or confirm that it was not flakiness that caused
them to fail.

**Other optional command line arguments**

- `--test-timeout=SECONDS` or `ENV[MINITEST_TEST_TIMEOUT_SECONDS]` (default: 30s):
  the maximum amount a test is allowed to run before it times out. In a distributed
  system, it's impossible to differentiate between a worker being slow and a
  worker being broken. When the timeout passes, the other workers will assume
  that the worker running the test has crashed, and will attempt to claim this
  test. This value should be comfortably higher than your slowest test.
- `--max-attempts=NUMBER` or `ENV[MINITEST_MAX_ATTEMPTS]` (default: 3). The
  maximum number of times a test is attempted to be run, before considering
  it failed. Higher values will prevent more flakiness, but will make the full
  test run slower.
- `--test-batch-size=NUMBER` or `ENV[MINITEST_TEST_BATCH_SIZE]` (default: 10).
  The amount of tests to process per batch. Lower numbers will make the
  distribution of tests more granular and even, but increase the load on the
  coordinator.
- `--worker-id=IDENTIFIER` or `ENV[MINITEST_WORKER_ID]`: The ID of the worker,
  which should be unique to the cluster. We will default to a UUID if this is
  not set, which generally is fine.
- `--exclude-file=PATH_TO_FILE`: Specify a file of tests to be excluded
  from running. The file should include test identifiers seperated by
  newlines.
- `--include-file=PATH_TO_FILE`: Specify a file of tests to be included in
  the test run. The file should include test identifiers seperated by
  newlines.

**Limitations**

**Parallel tests not supported:** Minitest comes bundled with a parallel test
executor, which will run tests that are specifically tagged as such in
parallel in the same process. `minitest-distributed` is designed to run tests
in parallel  using separate processes, generally on different VMs. For this
reason, tests marked as `parallel` will not be treated any differently than
other tests.

## How to use this repo
Add `minitest-distributed` to your `Gemfile`, and run `bundle install`. The
plugin will be loaded by minitest automatically. The plugin exposes some
command line arguments that you can use to influence its behavior. They can
also be set using environment variables.

## Contribute to this repo
Bug reports and pull requests are welcome on GitHub at
https://github.com/Shopify/minitest-distributed. This project is intended to
be a safe, welcoming space for collaboration, and contributors are expected to
adhere to the [code of
conduct](https://github.com/Shopify/minitest-distributed/blob/main/CODE_OF_CONDUCT.md).

**Development**

To bootstrap a local development environment:

- Run `bin/setup` to install dependencies.
- Start a Redis server by running `redis-server`, assuming you have Redis
  installed locally and the binary is on your `PATH`. Alternatively, you can
  set the `REDIS_URL` environment variable to point to a Redis instance running
  elsewhere. You can also use `docker-compose up` with the provided `docker-compose.yml`.
- Now, run `bin/rake test` to run the tests, and verify everything is working.
- You can also run `bin/console` for an interactive prompt that will allow you
  to experiment.

**Releasing a new version**

- To install this gem onto your local machine, run `bin/rake install`.
- Only people at Shopify can release a new version to
  [rubygems.org](https://rubygems.org). To do so, update the `VERSION` constant
  in `version.rb`, and merge to main. Shipit will take care of building the
  `.gem` bundle, and pushing it to rubygems.org.

## License
The gem is available as open source under the terms of the [MIT
License](https://opensource.org/licenses/MIT).
