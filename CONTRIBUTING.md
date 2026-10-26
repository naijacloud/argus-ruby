# Contributing

## Setup

Nothing to install. The gem has no runtime dependencies, and minitest and rake
ship with Ruby.

```sh
rake test
```

or, without bundler or rake at all:

```sh
ruby -Ilib -Itest test/errors_test.rb
```

## Tests

The suite runs **offline**. `test/test_helper.rb` starts a small HTTP server on
`127.0.0.1` with an ephemeral port, built on raw `TCPServer` (webrick left the
standard library in Ruby 3.0). There is no WebMock and no VCR, and no test
makes an outbound connection.

```ruby
@server.enqueue(status: 429, headers: { "Retry-After" => "7" })
@server.enqueue(status: 500)
```

Unscripted requests get a 200. Gzipped bodies are decoded for you, and
`envelope(request)` / `event_from(request)` parse an error envelope.

Retry timing is asserted, not slept through: `capture_sleeps(client)` (or
`transport.sleeper = ->(s) { ... }`) records the waits instead of waiting.

**Rails.** `test/rails_test.rb` boots a minimal Rails app in a child process.
It is skipped when Rails is not installed, which keeps the default suite
dependency-free. To run it:

```sh
gem install railties activejob
ruby -Ilib -Itest test/rails_test.rb
```

CI runs it against Rails 7.1, 7.2 and 8.0.

**Contract test.** `rake contract` sends one of each signal to a real Argus
and checks every endpoint answered 2xx:

```sh
ARGUS_CONTRACT_DSN=<dsn of a test source> rake contract
```

It expects a cron monitor with slug `argus-ruby-contract`; without one, the
cron check-in's 404 is reported, not failed.

## What to keep in mind when changing this gem

- **The contract is binding.** `nc-argus/spec/README.md` (`argus.sdk/1`) is the
  document every Argus SDK implements. A behaviour change here is owed to the
  others too. If the contract and ingest disagree, ingest wins and the contract
  gets fixed.
- **Never raise into the app, never block it.** Public methods go through
  `NaijaCloud::Argus.safely`; sending happens on the transport's threads.
- **Zero runtime dependencies.** See SECURITY.md.
- **Ruby 3.0 is the supported floor,** but keep the code 2.7-compatible: no
  endless methods, no `Hash#except`, no pattern matching. And no keyword
  arguments on a method that also takes an attributes hash: on Ruby 3 a
  braceless `"key" => value` would be taken for keywords.

## House style

Comments explain **why**: the decision, the failure it prevents, the trap it
avoids. `# frozen_string_literal: true` at the top of every file.

## Releasing

1. Update `lib/naijacloud/argus/version.rb`.
2. Move the `Unreleased` changelog entries under `## [x.y.z] - YYYY-MM-DD` and
   update the link definitions at the foot of the file.
3. Tag and push: `git tag v<version> && git push origin v<version>`.

`.github/workflows/release.yml` runs CI, refuses a tag that disagrees with
`VERSION` or has no changelog section, builds and pushes the gem with RubyGems
trusted publishing, then creates the GitHub release.

### One-time setup

- **rubygems.org → Settings → Trusted publishers → Create a pending trusted
  publisher:** gem `naijacloud-argus`, owner `naijacloud`, repository
  `argus-ruby`, workflow `release.yml`, environment `rubygems`.
- **GitHub → Settings → Environments → New environment `rubygems`.** Add
  required reviewers to make a push wait for a human.
