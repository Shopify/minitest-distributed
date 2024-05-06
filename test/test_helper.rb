# typed: strict
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "minitest/distributed"
require "minitest/autorun"

# Load test helpers
require_relative "lib/integration_test"
require_relative "lib/redis_integration_test"

require "toxiproxy"

Toxiproxy.host = ENV.fetch("TOXIPROXY_HOST", "http://0.0.0.0:8474")

Toxiproxy.populate([
  {
    name: "redis",
    listen: "0.0.0.0:22220",
    upstream: "redis:6379",
  },
])
