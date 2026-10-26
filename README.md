<p align="center">
  <a href="https://www.naijacloud.com/argus">
    <img alt="Naijacloud Argus, Ruby SDK" src="https://raw.githubusercontent.com/naijacloud/argus-ruby/main/.github/assets/banner.png" width="100%">
  </a>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/naijacloud-argus"><img alt="gem" src="https://img.shields.io/badge/gem-naijacloud--argus-008751?style=flat-square&labelColor=0A0E0C"></a>
  <img alt="ruby" src="https://img.shields.io/badge/ruby-%3E%3D_3.0-E0483F?style=flat-square&labelColor=0A0E0C">
  <img alt="dependencies" src="https://img.shields.io/badge/dependencies-0-46C98A?style=flat-square&labelColor=0A0E0C">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-8A988F?style=flat-square&labelColor=0A0E0C"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#rails">Rails</a> ·
  <a href="#rack-sinatra-and-plain-ruby">Rack</a> ·
  <a href="#errors">Errors</a> ·
  <a href="#logs-metrics-and-traces">Logs, metrics, traces</a> ·
  <a href="#cron-check-ins">Crons</a> ·
  <a href="#feature-flags">Flags</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="#options">Options</a>
</p>

# naijacloud-argus

The official Ruby SDK for [Argus](https://www.naijacloud.com/argus),
Naijacloud's monitoring. One gem sends errors, logs, metrics, traces, cron
check-ins and feature-flag checks, with one key: your app's **DSN**.

It has no runtime dependencies (standard-library `net/http`, `json` and `zlib`
only), implements the Argus SDK contract **`argus.sdk/1`**, and works for apps
hosted anywhere, not only on Naijacloud.

**Already using `sentry-ruby`?** Keep it. Argus accepts it: point its `dsn` at
Argus and you're done. Switch to this gem when you want logs, metrics, cron
check-ins and flags through the same setup.

## Install

```sh
bundle add naijacloud-argus
```

Ruby 3.0 or newer. Copy the DSN (your app's key) from the source in Argus. It
looks like `https://<key>@argus-in.naijacloud.com/<number>`.

## Rails

```sh
bundle add naijacloud-argus
ARGUS_DSN=https://…@argus-in.naijacloud.com/41 bin/rails server
```

That's the whole setup. The gem's Railtie:

- **starts Argus** after your initializers, reading `ARGUS_DSN`,
  `ARGUS_RELEASE` and `ARGUS_ENVIRONMENT` (falling back to `SENTRY_DSN`,
  `SENTRY_RELEASE` and `SENTRY_ENVIRONMENT`). With no environment variable set,
  the environment is `Rails.env` and the service name is your app's name;
- **traces every request**, named by its route (`GET /orders/:id`), and
  continues a `traceparent` header from the caller;
- **reports unhandled exceptions** with the request they came from. A 404 or a
  bad CSRF token is not reported;
- **reports ActiveJob failures** with the job's class, id and queue, and traces
  each job. Your `retry_on` and `discard_on` still behave as before;
- **subscribes to `Rails.error`** (Rails 7.0+), so `Rails.error.report` and
  `Rails.error.handle` reach Argus too;
- **traces outgoing `Net::HTTP` calls** (and Faraday, HTTParty and anything else
  built on it) and adds a `traceparent` header to them.

Without a DSN it does nothing, so development and test need no changes. Apps
hosted on Naijacloud get these variables set when the Argus tab is on.

To change options, add an initializer. It runs before the Railtie's own start,
so it wins:

```ruby
# config/initializers/argus.rb
NaijaCloud::Argus.init do |c|
  c.release = ENV["GIT_SHA"]
  c.traces_sample_rate = 0.2
  c.rails_logs = true   # also send Rails.logger lines to Argus Logs
end
```

## Rack, Sinatra and plain Ruby

```ruby
# config.ru
require "naijacloud/argus"
NaijaCloud::Argus.init            # reads ARGUS_DSN
use NaijaCloud::Argus::Rack
run App
```

The middleware gives you the same request spans and error reports as on Rails,
for Sinatra, Hanami, Roda, Grape and plain Rack.

**In a script or a worker,** call `init` at the top. An exception that ends the
process is reported, and whatever is queued is sent before the process exits.

```ruby
require "naijacloud/argus"
NaijaCloud::Argus.init(dsn: ENV["ARGUS_DSN"], release: "1.4.2")
```

## Errors

```ruby
begin
  charge_card(order)
rescue Paystack::Error => e
  NaijaCloud::Argus.capture_exception(e, tags: { provider: "paystack" }, extra: { order_id: order.id })
  raise
end

NaijaCloud::Argus.capture_message("Webhook signature mismatch", level: :warning)
NaijaCloud::Argus.set_user(id: current_user.id)
NaijaCloud::Argus.set_tag("region", "af-west")
NaijaCloud::Argus.add_breadcrumb(category: "cart", message: "coupon applied", data: { code: "NAIJA10" })
```

- **Causes:** an exception's `cause` chain is sent too.
- **Duplicates:** the same exception object is sent once, however many layers
  (Rack, `Rails.error`, ActiveJob) see it.
- **Per request:** `set_user`, tags and breadcrumbs set during a request (or a
  job) stay with that request; they don't leak to the next one on the same
  thread or to other threads.
- **`before_send`** lets you change an event (a Hash), or return `nil` to drop it.
- `capture_exception` returns the event id, or `nil` when nothing was sent.

## Logs, metrics and traces

```ruby
NaijaCloud::Argus.log.info("order placed", order_id: "ord_81", total: 18_500)
NaijaCloud::Argus.log.error("paystack timed out", attempt: 3)

NaijaCloud::Argus.metrics.count("orders.placed", 1, method: "card")
NaijaCloud::Argus.metrics.gauge("queue.depth", jobs.size)
NaijaCloud::Argus.metrics.distribution("checkout.ms", elapsed_ms, nil, "ms")

NaijaCloud::Argus.trace("charge card", provider: "paystack") do |span|
  span.set_attribute("amount", order.total)
  paystack.charge(order)
end
```

- **Logs** are sent in batches every 5 seconds (or every 1,000 lines). A line
  written inside a request carries that request's trace id.
- **A `::Logger`** that sends to Argus Logs, for any library that takes one:
  `NaijaCloud::Argus::Logger.new(level: :info)`. On Rails 7.1+,
  `Rails.logger.broadcast_to(NaijaCloud::Argus::Logger.new)` keeps your normal
  log output and adds Argus (or set `rails_logs = true`).
- **Metrics** are added up in the process and sent every 10 seconds.
- **Spans** join the request or job they run in. `trace` returns the block's
  value; an exception marks the span failed and is re-raised. For work that
  doesn't fit a block, `span = NaijaCloud::Argus.start_span("upload")` and later
  `span.finish` (or `span.finish(error)`).
- **Propagate a trace** through something the gem doesn't instrument (a queue
  message, gRPC metadata) with `NaijaCloud::Argus.traceparent`.
- **Sample traces** with `traces_sample_rate` (0 to 1, default 1).

## Cron check-ins

Create a cron monitor in Argus first, then report runs by its slug:

```ruby
NaijaCloud::Argus.monitor("nightly-invoices") do
  InvoiceRun.call
end

# or by hand:
NaijaCloud::Argus.cron.check_in("nightly-invoices", :start)
NaijaCloud::Argus.cron.check_in("nightly-invoices", :ok)    # or :error, or an exit code
```

`monitor` reports the start, then success or failure, and re-raises your job's
exception. An unknown slug is answered 404 by Argus and dropped.

## Feature flags

```ruby
if NaijaCloud::Argus.flags.on?("new-checkout", current_user.id)
  # …
end
theme = NaijaCloud::Argus.flags.variant("theme", current_user.id, "light")
NaijaCloud::Argus.flags.all(current_user.id)  # => {"new-checkout"=>"on", "theme"=>"dark"}
```

- **Caching:** answers are cached for 30 seconds per user (and attributes).
- **Fallback:** if Argus can't be reached within 2 seconds, or the flag doesn't
  exist, you get the fallback you passed.
- **Targeting attributes** go last: `on?("beta", user.id, false, plan: "pro")`.

## Privacy

On by default:

- The values of keys such as `password`, `token`, `secret`, `authorization`,
  `cookie`, `bvn` and `card` are replaced with `[Filtered]`, at any depth: in
  extra, contexts, breadcrumbs, log and span attributes.
- Card numbers, bearer tokens, JWTs and `password=…` pairs are filtered inside
  strings, including exception messages and log lines.
- Query strings are removed from URLs in requests, breadcrumbs and spans.
- Request bodies and cookies are never sent.
- The user's IP address is not sent unless you set `send_default_pii: true`.

Argus filters again on arrival.

## Options

Pass them to `init` as keywords, or set them in its block.

| Option | Default | |
| -- | -- | -- |
| `dsn` | `ARGUS_DSN`, then `SENTRY_DSN` | Without one, nothing is sent |
| `release` | `ARGUS_RELEASE`, then `SENTRY_RELEASE` | Your app's version, like `1.4.2` or a git commit |
| `environment` | `ARGUS_ENVIRONMENT`, then `SENTRY_ENVIRONMENT`, else `production` (`Rails.env` on Rails) | |
| `service_name` | `ARGUS_SERVICE_NAME`, else `app` (the app's name on Rails) | Shown on logs, metrics and traces |
| `sample_rate` | `1.0` | Share of errors sent |
| `traces_sample_rate` | `1.0` | Share of traces sent |
| `send_default_pii` | `false` | Send the user's IP address |
| `max_breadcrumbs` | `100` | |
| `before_send` / `before_breadcrumb` | | Change or drop an event or crumb (return `nil`) |
| `excluded_exceptions` | 404-type Rails errors | Class names never reported |
| `project_root` | `Rails.root` on Rails | Frames under it are marked in-app |
| `context_lines` | `true` | Send the lines of source around in-app frames |
| `net_http` | `true` | Trace outgoing `Net::HTTP` calls |
| `trace_propagation` | `true` | Add `traceparent` to outgoing requests |
| `rails_logs` | `false` | Also send `Rails.logger` lines as logs |
| `capture_at_exit` | `true` | Report the exception that ends the process |
| `debug` | `false` | Print what the SDK does to `$stderr` (or `ARGUS_DEBUG=1`) |
| `enabled` | `true` | Turn the SDK off without removing it |

The gem never raises into your app and never blocks a request: everything is
sent from background threads, with retries and backoff. Call
`NaijaCloud::Argus.flush` before a short script exits if it calls `exit!`;
otherwise the exit hook sends what's queued. It is safe with forking servers
(Puma, Unicorn) and job runners (Sidekiq, Resque): each child process starts
its own sender.

## Not in this version

These are planned, and not done yet:

- automatic spans for ActiveRecord queries, Redis and view rendering;
- trace propagation from a request into the jobs it enqueues;
- reporting an ActiveJob failure only after its retries are used up (every
  failed attempt is reported today).

## License

MIT
