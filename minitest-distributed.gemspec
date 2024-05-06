require_relative 'lib/minitest/distributed/version'

Gem::Specification.new do |spec|
  spec.name          = "minitest-distributed"
  spec.version       = Minitest::Distributed::VERSION
  spec.authors       = ["Willem van Bergen"]
  spec.email         = ["willem@vanbergen.org"]

  spec.summary       = "Distributed test executor plugin for Minitest"
  spec.description   = <<~EOD
    minitest-distributed is a plugin for minitest for executing tests on a
    distributed set of unreliable workers.

    When a test suite grows large enough, it inevitable gets too slow to run
    on a single machine to give timely feedback to developers. This plugins
    combats this issue by distributing the full test suite to a set of workers.
    Every worker is a consuming from a single queue, so the tests get evenly
    distributed and all workers will finish around the same time. Redis is used
    as coordinator, but when using this plugin without having access to Redis,
    it will use an in-memory coordinator.

    Using multiple (virtual) machines for a test run is an (additional) source
    of flakiness. To combat flakiness, minitest-distributed implements resiliency
    patterns, like re-running a test on a different worker on failure, and
    a circuit breaker for misbehaving workers.
  EOD

  spec.homepage      = "https://github.com/Shopify/minitest-distributed"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Shopify/minitest-distributed"
  # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features|.shopify-build|.github)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency('minitest', '~> 5.12')
  spec.add_dependency('redis', '>= 5.0.6', '< 6')
  spec.add_dependency('sorbet-runtime')
end
