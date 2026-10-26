# frozen_string_literal: true

require_relative "lib/naijacloud/argus/version"

Gem::Specification.new do |spec|
  spec.name    = "naijacloud-argus"
  spec.version = NaijaCloud::Argus::VERSION
  spec.authors = ["Naija Cloud"]
  spec.email   = ["support@naijacloud.com"]

  spec.summary     = "Ruby SDK for Naijacloud Argus: errors, logs, metrics, traces, cron check-ins and feature flags."
  spec.description = "The official Ruby SDK for Argus, Naijacloud's monitoring. Implements the Argus SDK " \
                     "contract argus.sdk/1, with Rack middleware and a Rails Railtie. " \
                     "No runtime dependencies: standard-library net/http, json and zlib only."
  spec.homepage = "https://github.com/naijacloud/argus-ruby"
  spec.license  = "MIT"

  # 3.0 is the supported floor. The code itself stays 2.7-compatible (no
  # endless methods, no Hash#except, no pattern matching) so the suite also
  # runs on the oldest Ruby in our fleet, but 2.7 is end-of-life and is not
  # promised to customers.
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "documentation_uri" => "https://www.naijacloud.com/docs/argus",
    # Installed into every process an app runs, with sight of its errors and
    # requests. An account takeover on a maintainer would be a supply-chain
    # incident for every customer, so publishing requires a second factor.
    "rubygems_mfa_required" => "true",
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "LICENSE",
    "CHANGELOG.md",
    "SECURITY.md",
    "CONTRIBUTING.md",
  ]
  spec.require_paths = ["lib"]

  # Deliberately no runtime dependencies -- see SECURITY.md.
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
