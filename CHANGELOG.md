# Changelog

All notable changes to `naijacloud-argus` are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the gem uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-26

First release, implementing the Argus SDK contract `argus.sdk/1`.

### Added

- `NaijaCloud::Argus.init`, with keywords or a block. Reads `ARGUS_DSN`,
  `ARGUS_RELEASE` and `ARGUS_ENVIRONMENT`, then the `SENTRY_*` names. Without a
  DSN every call is a no-op.
- **Errors:** `capture_exception` (with the `cause` chain and source context
  lines), `capture_message`, `set_user`, `set_tag(s)`, `set_context`,
  `add_breadcrumb`, `with_scope`, `before_send`, `before_breadcrumb`,
  `excluded_exceptions`. Sent as gzipped Sentry envelopes.
- **Rails** (Railtie, no setup beyond `bundle add` and `ARGUS_DSN`): request
  tracing named by route, unhandled exceptions, ActiveJob failures and spans, a
  `Rails.error` subscriber, and optional `Rails.logger` forwarding
  (`rails_logs`).
- **Rack middleware** `NaijaCloud::Argus::Rack` for Sinatra, Hanami, Roda,
  Grape and plain Rack: server spans continuing W3C `traceparent`, and
  unhandled exceptions with the request.
- **Outgoing `Net::HTTP`**: client spans, `traceparent` propagation and
  breadcrumbs.
- **Logs, metrics and traces** over OTLP/HTTP JSON: `log.info` and the other
  levels, a `::Logger`-compatible `NaijaCloud::Argus::Logger`,
  `metrics.count` / `gauge` / `distribution`, `trace` and `start_span`.
- **Cron check-ins by monitor slug:** `cron.check_in` and `monitor`.
- **Feature flags:** `flags.on?`, `flags.variant` and `flags.all`, cached 30 s.
- **Transport:** one background thread and bounded queue per endpoint, retries
  with backoff, `Retry-After` on 429, stops on a refused key, fork-safe, never
  raises. Uncaught exceptions are reported and queues flushed at exit.
- **Privacy defaults on:** sensitive keys, card numbers, tokens and JWTs are
  filtered; query strings, cookies and IP addresses are not sent.

[Unreleased]: https://github.com/naijacloud/argus-ruby/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/naijacloud/argus-ruby/releases/tag/v0.1.0
