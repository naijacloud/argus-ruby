# frozen_string_literal: true

require_relative "argus/version"
require_relative "argus/dsn"
require_relative "argus/scrub"
require_relative "argus/otlp"
require_relative "argus/transport"
require_relative "argus/stack"
require_relative "argus/span"
require_relative "argus/scope"
require_relative "argus/configuration"
require_relative "argus/client"
require_relative "argus/integrations/rack"

module NaijaCloud
  # The official Ruby SDK for Naijacloud Argus (contract `argus.sdk/1`).
  #
  #   NaijaCloud::Argus.init                     # reads ARGUS_DSN
  #   NaijaCloud::Argus.capture_exception(err)
  #
  # Every method here is safe to call before `init`, without a DSN, or after
  # `close`: it does nothing. None of them raises, whatever Argus or the
  # network does.
  module Argus
    # ::Logger-compatible sink; loaded on first use so apps that never touch it
    # do not load the logger library.
    autoload :Logger, File.expand_path("argus/logger", __dir__)

    @client = nil
    @mutex = Mutex.new
    @at_exit_installed = false

    class << self
      # Starts Argus. Options win over ARGUS_* and then SENTRY_* environment
      # variables. A second call returns the client the first one made.
      #
      #   NaijaCloud::Argus.init(dsn: "https://…@argus-in.naijacloud.com/41")
      #   NaijaCloud::Argus.init { |c| c.release = "1.4.2"; c.traces_sample_rate = 0.2 }
      def init(**options)
        @mutex.synchronize do
          return @client if @client

          config = Configuration.new(**options)
          yield config if block_given?
          config.resolve!
          @client = Client.new(config)
          install(@client)
          @client
        end
      rescue StandardError => e
        warn("[argus] init failed: #{e.class}: #{e.message}") if options[:debug]
        nil
      end

      # The client init made, or nil.
      def client
        @client
      end

      def initialized?
        !@client.nil?
      end

      # Whether init found a DSN and the SDK is sending.
      def enabled?
        !!@client&.enabled?
      end

      # ---- errors ----

      # Sends an exception. Returns the event id, or nil when nothing was sent.
      # Options: level:, tags:, extra:, user:, contexts:, fingerprint:,
      # request:, transaction:.
      def capture_exception(exception, **context)
        safely(nil) { @client&.capture_exception(exception, **context) }
      end

      def capture_message(message, level: :info, **context)
        safely(nil) { @client&.capture_message(message, level: level, **context) }
      end

      # `set_user(id: "u_1", email: "ada@example.com")`, or `set_user(nil)`.
      def set_user(user = nil, **fields)
        safely { @client&.set_user(user.nil? && fields.empty? ? nil : (user || {}).merge(fields)) }
      end

      def set_tag(key, value)
        safely { @client&.set_tag(key, value) }
      end

      def set_tags(tags)
        safely { @client&.set_tags(tags) }
      end

      def set_context(name, context)
        safely { @client&.set_context(name, context) }
      end

      # `add_breadcrumb(category: "auth", message: "signed in", data: {...})`
      def add_breadcrumb(crumb = nil, **fields)
        safely { @client&.add_breadcrumb((crumb || {}).merge(fields)) }
      end

      # Runs the block with its own user, tags and breadcrumbs, so what it sets
      # is not seen by other threads. The Rack middleware does this per request.
      def with_scope(&block)
        return yield(nil) unless @client

        @client.with_scope(&block)
      end

      # ---- logs, metrics, traces ----

      # `NaijaCloud::Argus.log.info("order placed", order_id: "ord_81")`
      def log
        LOG
      end

      # `NaijaCloud::Argus.metrics.count("orders.placed", 1, method: "card")`
      def metrics
        METRICS
      end

      # Runs the block inside a span and yields it. The block's return value is
      # returned; its exception marks the span failed and is re-raised.
      # Without a DSN the block still runs, with a span that records nothing.
      def trace(name, attributes = nil, &block)
        client = @client
        return yield(Span.new(nil, name)) if client.nil?

        client.trace(name, attributes, &block)
      end

      # Starts a span you finish yourself (`span.finish`).
      def start_span(name, attributes = nil, kind = Span::KIND_INTERNAL)
        safely(nil) { @client&.start_span(name, attributes: attributes, kind: kind) } || Span.new(nil, name)
      end

      # The current span, if any.
      def current_span
        Span.current
      end

      # The W3C traceparent for the current span, for propagating a trace
      # through something the SDK does not instrument (a queue, a gRPC call).
      def traceparent
        Span.current&.traceparent
      end

      # ---- crons and flags ----

      # `NaijaCloud::Argus.cron.monitor("nightly-invoices") { send_invoices }`
      def cron
        CRON
      end

      # `NaijaCloud::Argus.flags.on?("new-checkout", user.id)`
      def flags
        FLAGS
      end

      # Shorthand for `cron.monitor(slug) { ... }`.
      def monitor(slug, &block)
        CRON.monitor(slug, &block)
      end

      # ---- lifecycle ----

      # Sends what's queued. True when it all went out within timeout seconds.
      def flush(timeout = 2.0)
        safely(true) { @client ? @client.flush(timeout) : true }
      end

      # Flushes and stops the SDK. `init` can be called again afterwards.
      def close(timeout = 2.0)
        c = @mutex.synchronize do
          old = @client
          @client = nil
          old
        end
        safely(true) { c ? c.close(timeout) : true }
      end

      # Runs SDK code so that nothing it does can raise into the app.
      def safely(fallback = nil)
        yield
      rescue StandardError => e
        if @client&.config&.debug
          begin
            @client.config.debug_output&.puts("[argus] #{e.class}: #{e.message}")
          rescue StandardError
            nil
          end
        end
        fallback
      end

      private

      def install(client)
        return unless client.enabled?

        install_at_exit
        if client.config.net_http
          require_relative "argus/integrations/net_http"
          Integrations::NetHTTP.install
        end
      end

      # A script that dies of an uncaught exception reports it, and every
      # process sends what is still queued (spec §6: flush on exit).
      def install_at_exit
        return if @at_exit_installed

        @at_exit_installed = true
        at_exit do
          c = @client
          if c
            err = $!
            if c.config.capture_at_exit && err && !err.is_a?(SystemExit) && !err.is_a?(SignalException)
              safely { c.capture_exception(err, level: :fatal, tags: { mechanism: "at_exit" }) }
            end
            safely { c.flush(2.0) }
          end
        end
      end
    end

    # `NaijaCloud::Argus.log`: logs to Argus Logs. Attributes are a Hash.
    module LogAPI
      extend self

      %i[trace debug info warn error fatal].each do |level|
        define_method(level) do |message, attributes = nil|
          Argus.safely { Argus.client&.log(level, message, attributes) }
          nil
        end
      end
    end
    LOG = LogAPI

    # `NaijaCloud::Argus.metrics`: aggregated in process, sent every 10 s.
    module MetricsAPI
      extend self

      # Adds to a counter (default 1).
      def count(name, value = 1, attributes = nil)
        Argus.safely { Argus.client&.count(name, value, attributes) }
        nil
      end

      # Sets a gauge to its latest value.
      def gauge(name, value, attributes = nil, unit = nil)
        Argus.safely { Argus.client&.gauge(name, value, attributes, unit) }
        nil
      end

      # Records a value into a histogram (durations, sizes).
      def distribution(name, value, attributes = nil, unit = nil)
        Argus.safely { Argus.client&.distribution(name, value, attributes, unit) }
        nil
      end
    end
    METRICS = MetricsAPI

    # `NaijaCloud::Argus.cron`: check-ins by the monitor's slug. Create the
    # monitor in Argus first; an unknown slug is answered 404 and dropped.
    module CronAPI
      extend self

      # status: :start, :ok, :error, or an exit code.
      def check_in(slug, status = :ok, output = nil)
        Argus.safely { Argus.client&.check_in(slug, status, output) }
        nil
      end

      # Reports the start, then success or failure, and re-raises the block's
      # exception. Without a DSN the block just runs.
      def monitor(slug)
        client = Argus.client
        return yield if client.nil? || !client.enabled?

        Argus.safely { client.check_in(slug, :start) }
        begin
          result = yield
        rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised
          Argus.safely { client.check_in(slug, :error, "#{e.class}: #{e.message}") }
          raise
        end
        Argus.safely { client.check_in(slug, :ok) }
        result
      end
    end
    CRON = CronAPI

    # `NaijaCloud::Argus.flags`: evaluated by Argus for a subject (usually a
    # user id). Answers are cached 30 s; on any failure you get the fallback.
    module FlagsAPI
      extend self

      def on?(key, subject, fallback = false, attributes = nil)
        result = Argus.safely(nil) { Argus.client&.on?(key, subject, fallback, attributes) }
        result.nil? ? fallback : result
      end
      alias enabled? on?

      def variant(key, subject, fallback = nil, attributes = nil)
        result = Argus.safely(nil) { Argus.client&.variant(key, subject, fallback, attributes) }
        result.nil? ? fallback : result
      end

      def all(subject, attributes = nil)
        Argus.safely({}) { Argus.client ? Argus.client.evaluate_flags(subject, attributes) : {} }
      end
    end
    FLAGS = FlagsAPI
  end
end

require_relative "argus/integrations/rails" if defined?(::Rails::Railtie)
