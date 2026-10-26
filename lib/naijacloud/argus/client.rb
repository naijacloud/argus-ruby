# frozen_string_literal: true

require "json"
require "securerandom"
require "socket"
require "stringio"
require "time"
require "zlib"

module NaijaCloud
  module Argus
    # Does the work behind the module-level API. One per process, made by
    # `NaijaCloud::Argus.init`. Without a DSN it is disabled and every method
    # returns immediately.
    class Client
      LEVELS = %w[fatal error warning info debug].freeze
      LOG_SEVERITIES = %i[trace debug info warn error fatal].freeze

      FLUSH_LOGS = 5
      FLUSH_SPANS = 5
      FLUSH_METRICS = 10
      MAX_LOGS = 1000
      MAX_SPANS = 512
      MAX_SERIES = 2000
      MAX_TAGS = 50
      MAX_LOG_BODY = 16_384
      MAX_CRON_OUTPUT = 2048
      FLAG_CACHE_TTL = 30
      # Request bodies stay under the transport's 1 MiB queue bound (spec §6),
      # which is also under every endpoint's body limit (spec §3).
      MAX_BODY = 1_000_000
      HIST_BOUNDS = [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000].freeze

      attr_reader :config, :dsn, :transport, :global_scope

      def initialize(config)
        @config = config
        @dsn = config.enabled == false ? nil : Dsn.parse(config.dsn)
        debug("the DSN is not valid; nothing will be sent") if config.dsn && @dsn.nil?
        @transport = Transport.new(debug: method(:debug))
        @stack = Stack.new(project_root: config.project_root, context_lines: config.context_lines)
        @global_scope = Scope.new(config.max_breadcrumbs.to_i)
        @server_name = config.server_name || hostname
        @mutex = Mutex.new
        @log_buf = []
        @span_buf = []
        @metrics = {}
        @metric_start = Time.now.to_f
        @flag_cache = {}
        @closed = false
        @pid = Process.pid
        @next = { logs: now + FLUSH_LOGS, spans: now + FLUSH_SPANS, metrics: now + FLUSH_METRICS }
        @ticker = nil
        @tick_cv = ConditionVariable.new
        start_ticker if enabled?
      end

      # Whether a DSN was given and the SDK will send anything.
      def enabled?
        !@dsn.nil? && !@closed
      end

      # ---- scope ----

      def current_scope
        Scope.current || @global_scope
      end

      def set_user(user)
        current_scope.user = user.nil? ? nil : symbolize(user)
      end

      def set_tag(key, value)
        current_scope.set_tag(key, value)
      end

      def set_tags(tags)
        tags.each { |k, v| set_tag(k, v) }
      end

      def set_context(name, ctx)
        current_scope.set_context(name, ctx)
      end

      def add_breadcrumb(crumb)
        c = { timestamp: Time.now.to_f }.merge(symbolize(crumb))
        c[:level] = normalize_level(c[:level]) if c[:level]
        if @config.before_breadcrumb
          begin
            c = @config.before_breadcrumb.call(c)
          rescue StandardError
            nil # keep the crumb
          end
        end
        current_scope.add_breadcrumb(c) if c
      end

      # Runs the block with a fresh scope (the Rack middleware does this per
      # request), so what it sets does not leak to other requests.
      def with_scope(&block)
        Scope.with(Scope.new(@config.max_breadcrumbs.to_i), &block)
      end

      # ---- errors ----

      # Sends an exception. Returns its event id, or nil when nothing was sent.
      def capture_exception(exception, **ctx)
        return nil unless enabled?
        return nil if excluded?(exception)
        return nil if already_captured?(exception)

        send_event({ exception: { values: exception_chain(exception) } }, ctx)
      end

      def capture_message(message, level: :info, **ctx)
        return nil unless enabled?

        send_event({ message: message.to_s }, ctx.merge(level: level))
      end

      # ---- logs ----

      def log(severity, body, attributes = nil)
        return unless enabled?

        severity = severity.to_sym
        severity = :warn if severity == :warning
        return unless LOG_SEVERITIES.include?(severity)

        span = Span.current
        rec = {
          time: Time.now.to_f, severity: severity,
          body: Scrub.scrub_string(body.to_s)[0, MAX_LOG_BODY],
          attributes: attributes && Scrub.scrub(attributes),
          trace_id: span&.trace_id, span_id: span&.span_id,
        }
        full = @mutex.synchronize do
          check_fork
          @log_buf << rec
          @log_buf.length >= MAX_LOGS
        end
        flush_logs if full
      end

      # ---- metrics ----

      def count(name, value = 1, attributes = nil)
        metric(:sum, name, value, attributes, nil)
      end

      def gauge(name, value, attributes = nil, unit = nil)
        metric(:gauge, name, value, attributes, unit)
      end

      def distribution(name, value, attributes = nil, unit = nil)
        metric(:histogram, name, value, attributes, unit)
      end

      # ---- traces ----

      def sample_trace?
        enabled? && rand < @config.traces_sample_rate.to_f
      end

      # Starts a span under the current one (or a new trace). Finish it yourself.
      def start_span(name, kind: Span::KIND_INTERNAL, attributes: nil, parent: nil)
        parent ||= (cur = Span.current) && { trace_id: cur.trace_id, span_id: cur.span_id, sampled: cur.sampled? }
        Span.new(enabled? ? self : nil, name, kind: kind, parent: parent, attributes: attributes)
      end

      # Runs the block inside a span that ends when the block does. An
      # exception from the block marks the span failed and is re-raised.
      # Positional, not keyword, options: on Ruby 3 a braceless attributes
      # hash (`trace("x", "job.kind" => "nightly")`) would otherwise be taken
      # for keywords and raise.
      def trace(name, attributes = nil, kind = Span::KIND_INTERNAL, parent = nil)
        span = start_span(name, kind: kind, attributes: attributes, parent: parent)
        begin
          result = Span.with(span) { yield span }
        rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised
          span.finish(e)
          raise
        end
        span.finish
        result
      end

      def record_span(data)
        return unless enabled?

        data[:attributes] = Scrub.scrub(data[:attributes]) if data[:attributes]
        full = @mutex.synchronize do
          check_fork
          @span_buf << data
          @span_buf.length >= MAX_SPANS
        end
        flush_spans if full
      end

      # ---- crons ----

      # Reports a run to the cron monitor with this slug: :start, :ok,
      # :error, or an exit code.
      def check_in(slug, status = :ok, output = nil)
        return unless enabled?

        suffix = case status
                 when :start, "start" then "/start"
                 when :ok, "ok", nil then ""
                 when :error, :fail, "error", "fail" then "/fail"
                 when Integer then "/#{status}"
                 else raise ArgumentError, "unknown check-in status #{status.inspect}"
                 end
        body = output ? Scrub.scrub_string(output.to_s)[0, MAX_CRON_OUTPUT] : ""
        enqueue("crons", "/v1/cron/#{escape(slug)}#{suffix}", body, "text/plain; charset=utf-8")
      end

      # Runs the block and reports it: start, then ok or fail. Re-raises.
      def monitor(slug)
        check_in(slug, :start)
        begin
          result = yield
        rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised
          check_in(slug, :error, "#{e.class}: #{e.message}")
          raise
        end
        check_in(slug, :ok)
        result
      end

      # ---- flags ----

      # Every flag's variant for a subject (usually a user id), cached for 30 s.
      # Waits at most 2 s for Argus; on any failure answers from the cache, or {}.
      def evaluate_flags(subject, attributes = nil)
        return {} unless enabled? && !subject.to_s.empty?

        attributes = (attributes || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
        key = "#{subject}|#{JSON.generate(attributes.sort)}"
        hit = @mutex.synchronize { @flag_cache[key] }
        return hit[:flags] if hit && now - hit[:at] < FLAG_CACHE_TTL
        return hit ? hit[:flags] : {} if @transport.dead?("flags") || @transport.blocked?("flags")

        flags = fetch_flags(subject.to_s, attributes)
        return hit ? hit[:flags] : {} if flags.nil?

        @mutex.synchronize do
          @flag_cache.clear if @flag_cache.size > 1000
          @flag_cache[key] = { at: now, flags: flags }
        end
        flags
      end

      def variant(key, subject, fallback, attributes = nil)
        evaluate_flags(subject, attributes).fetch(key.to_s, fallback)
      end

      def on?(key, subject, fallback = false, attributes = nil)
        v = variant(key, subject, fallback ? "on" : "off", attributes)
        %w[on true].include?(v.to_s)
      end

      # ---- sending ----

      def flush_logs
        batch = @mutex.synchronize { @log_buf.slice!(0, MAX_LOGS) }
        send_otlp("logs", "/v1/logs", batch) { |chunk| OTLP.logs(resource, chunk) }
      end

      def flush_spans
        batch = @mutex.synchronize { @span_buf.slice!(0, MAX_SPANS) }
        send_otlp("traces", "/v1/traces", batch) { |chunk| OTLP.traces(resource, chunk) }
      end

      def flush_metrics
        points = @mutex.synchronize do
          stop = Time.now.to_f
          start = @metric_start
          @metric_start = stop
          aggs = @metrics.values
          @metrics = {}
          aggs.map { |m| metric_point(m, start, stop) }
        end
        send_otlp("metrics", "/v1/metrics", points) { |chunk| OTLP.metrics(resource, chunk) }
      end

      # Sends everything queued. True when it all went out within timeout seconds.
      def flush(timeout = 2.0)
        return true unless @dsn

        flush_logs
        flush_spans
        flush_metrics
        @transport.flush(timeout)
      end

      # Flushes, then stops sending.
      def close(timeout = 2.0)
        ok = flush(timeout)
        @closed = true
        @mutex.synchronize { @tick_cv.broadcast }
        @transport.close
        ok
      end

      def inspect
        "#<NaijaCloud::Argus::Client #{@dsn ? @dsn.inspect : 'disabled'}>"
      end

      private

      def send_event(partial, ctx)
        return nil if rand >= @config.sample_rate.to_f

        event = build_event(partial, ctx)
        if @config.before_send
          begin
            event = @config.before_send.call(event)
          rescue StandardError => e
            debug("before_send raised #{e.class}; sending the event unchanged")
          end
          return nil unless event
        end
        event = symbolize(event)
        sdk = event.delete(:sdk) || { name: SDK_NAME, version: VERSION }
        clean = Scrub.scrub(event).merge("sdk" => sdk)
        clean["event_id"] = SecureRandom.hex(16) unless clean["event_id"].to_s =~ /\A\h{32}\z/
        envelope = [
          JSON.generate(event_id: clean["event_id"], sent_at: Time.now.utc.iso8601(3), dsn: @dsn.raw, sdk: sdk),
          JSON.generate(type: "event", content_type: "application/json"),
          JSON.generate(clean),
        ].join("\n") << "\n"
        @transport.enqueue("errors", Transport::Request.new(
          @dsn.envelope_url, gzip(envelope),
          {
            "Content-Type" => "application/x-sentry-envelope",
            "Content-Encoding" => "gzip",
            "X-Sentry-Auth" => "Sentry sentry_version=7, sentry_client=#{SDK_NAME}/#{VERSION}, sentry_key=#{@dsn.public_key}",
          },
        ))
        clean["event_id"]
      end

      def build_event(partial, ctx)
        scope = current_scope
        global = @global_scope.snapshot
        local = scope.equal?(@global_scope) ? nil : scope.snapshot
        span = Span.current
        tags = global[:tags].merge(local ? local[:tags] : {}).merge(stringify(ctx[:tags] || {}))
        crumbs = global[:breadcrumbs] + (local ? local[:breadcrumbs] : [])
        user = ctx[:user] ? symbolize(ctx[:user]) : (local && local[:user]) || global[:user]
        user = user.reject { |k, _| k == :ip_address } if user && !@config.send_default_pii
        contexts = default_contexts.merge(global[:contexts]).merge(local ? local[:contexts] : {}).merge(stringify(ctx[:contexts] || {}))
        contexts["trace"] = { trace_id: span.trace_id, span_id: span.span_id } if span
        transaction = ctx[:transaction] || (local && local[:transaction]) || span&.name

        event = {
          event_id: SecureRandom.hex(16),
          timestamp: Time.now.to_f,
          platform: "ruby",
          level: normalize_level(ctx[:level] || :error),
          release: @config.release && @config.release[0, 200],
          environment: @config.environment.to_s[0, 64],
          server_name: @server_name && @server_name[0, 200],
          transaction: transaction && transaction.to_s[0, 300],
          tags: tags.first(MAX_TAGS).to_h,
          user: user,
          breadcrumbs: { values: crumbs.last(@config.max_breadcrumbs.to_i) },
          contexts: contexts,
          extra: ctx[:extra],
          request: ctx[:request] || (local && local[:request]),
          fingerprint: ctx[:fingerprint]&.map(&:to_s),
          sdk: { name: SDK_NAME, version: VERSION },
        }.merge(partial)
        event.reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
      end

      def default_contexts
        {
          "runtime" => { name: "ruby", version: RUBY_VERSION, engine: RUBY_ENGINE },
          "os" => { name: RbConfig::CONFIG["host_os"] },
        }
      end

      # The exception and its causes, oldest (deepest cause) first, as
      # Argus expects: the last entry is the error itself.
      def exception_chain(exception)
        unless exception.is_a?(Exception)
          return [{ type: "Error", value: "Non-exception captured: #{safe_inspect(exception)}"[0, 1000] }]
        end

        out = []
        seen = {}
        cur = exception
        5.times do
          break unless cur.is_a?(Exception) && !seen[cur.object_id]

          seen[cur.object_id] = true
          frames = @stack.frames(cur)
          entry = { type: cur.class.name || cur.class.to_s, value: safe_message(cur)[0, 8192] }
          entry[:stacktrace] = { frames: frames } unless frames.empty?
          out.unshift(entry)
          cur = cur.cause
        end
        out
      end

      def excluded?(exception)
        return false unless exception.is_a?(Exception)

        names = exception.class.ancestors.map(&:name)
        Array(@config.excluded_exceptions).any? { |ex| names.include?(ex.is_a?(Module) ? ex.name : ex.to_s) }
      end

      # The same exception object is reported once, however many layers (Rack,
      # Rails.error, ActiveJob, at_exit) see it.
      def already_captured?(exception)
        return false unless exception.is_a?(Exception)
        return true if exception.instance_variable_defined?(:@__naijacloud_argus_captured)

        exception.instance_variable_set(:@__naijacloud_argus_captured, true)
        false
      rescue StandardError # frozen exceptions
        false
      end

      def metric(kind, name, value, attributes, unit)
        return unless enabled?
        return unless value.is_a?(Numeric) && value.to_f.finite?

        attributes = attributes ? stringify(attributes) : {}
        key = "#{kind}|#{name}|#{JSON.generate(attributes.sort)}"
        @mutex.synchronize do
          check_fork
          m = @metrics[key]
          unless m
            return if @metrics.size >= MAX_SERIES

            m = @metrics[key] = { kind: kind, name: name.to_s, unit: unit, attributes: attributes, value: 0.0,
                                  count: 0, sum: 0.0, min: Float::INFINITY, max: -Float::INFINITY,
                                  buckets: Array.new(HIST_BOUNDS.length + 1, 0) }
          end
          case kind
          when :sum then m[:value] += value
          when :gauge then m[:value] = value
          else
            m[:count] += 1
            m[:sum] += value
            m[:min] = value if value < m[:min]
            m[:max] = value if value > m[:max]
            m[:buckets][HIST_BOUNDS.index { |b| value <= b } || HIST_BOUNDS.length] += 1
          end
        end
      end

      def metric_point(m, start, stop)
        base = { kind: m[:kind], name: m[:name], unit: m[:unit], attributes: m[:attributes], start: start, end: stop }
        case m[:kind]
        when :sum, :gauge then base.merge(value: m[:value])
        else base.merge(count: m[:count], sum: m[:sum], min: m[:min], max: m[:max], bounds: HIST_BOUNDS, buckets: m[:buckets])
        end
      end

      def resource
        {
          "service.name" => @config.service_name,
          "service.version" => @config.release,
          "deployment.environment" => @config.environment,
          "host.name" => @server_name,
          "telemetry.sdk.name" => SDK_NAME,
          "telemetry.sdk.version" => VERSION,
          "telemetry.sdk.language" => "ruby",
          "argus.contract" => CONTRACT,
        }
      end

      # Splits a batch in half until each request fits under MAX_BODY.
      def send_otlp(lane, path, items, &build)
        return if items.empty? || @dsn.nil?

        body = JSON.generate(build.call(items))
        if body.bytesize > MAX_BODY
          if items.length == 1
            debug("#{lane}: one record over #{MAX_BODY} bytes, dropped")
          else
            half = items.length / 2
            send_otlp(lane, path, items[0, half], &build)
            send_otlp(lane, path, items[half..-1], &build)
          end
          return
        end
        enqueue(lane, path, body, "application/json")
      rescue StandardError => e
        debug("#{lane}: could not encode (#{e.class}: #{e.message})")
      end

      def enqueue(lane, path, body, content_type)
        @transport.enqueue(lane, Transport::Request.new(
          @dsn.ingest_url(path), body,
          { "Content-Type" => content_type, "Authorization" => "Bearer #{@dsn.public_key}" },
        ))
      end

      def fetch_flags(subject, attributes)
        url = @dsn.ingest_url("/v1/flags/evaluate")
        body = JSON.generate(subject: subject, environment: @config.environment, attributes: attributes)
        headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{@dsn.public_key}" }
        res = @transport.post(url, body, headers, read_timeout: 2, open_timeout: 2)
        observe("flags", url, res)
        code = res.code.to_i
        if [401, 403].include?(code)
          debug("flags: #{code}, the key was refused; stopping flag evaluation until restart")
          @transport.mark_dead("flags")
          return nil
        end
        if code == 429
          @transport.block("flags", Transport.retry_after(res))
          return nil
        end
        return nil unless code >= 200 && code < 300

        parsed = JSON.parse(res.body.to_s)
        flags = parsed.is_a?(Hash) && parsed["flags"].is_a?(Hash) ? parsed["flags"] : {}
        flags.transform_values(&:to_s)
      rescue StandardError => e
        debug("flags: #{e.class}: #{e.message}")
        observe("flags", url, nil) if url
        nil
      end

      def observe(lane, url, res)
        obs = @transport.observer
        return unless obs

        obs.call(Transport::Response.new(lane, url, res ? res.code.to_i : 0, {}))
      rescue StandardError
        nil
      end

      # One background thread wakes once a second and sends whatever batch is
      # due. It never runs app code and never raises.
      def start_ticker
        @ticker = Thread.new do
          Thread.current[:naijacloud_argus_internal] = true
          until @closed
            @mutex.synchronize { @tick_cv.wait(@mutex, 1) unless @closed }
            break if @closed

            tick
          end
        end
        @ticker.name = "argus-flush" if @ticker.respond_to?(:name=)
        @ticker.report_on_exception = false
      end

      def tick
        t = now
        if t >= @next[:logs]
          @next[:logs] = t + FLUSH_LOGS
          flush_logs
        end
        if t >= @next[:spans]
          @next[:spans] = t + FLUSH_SPANS
          flush_spans
        end
        if t >= @next[:metrics]
          @next[:metrics] = t + FLUSH_METRICS
          flush_metrics
        end
      rescue StandardError => e
        debug("flush: #{e.class}: #{e.message}")
      end

      # Called with @mutex held. After a fork the ticker thread is gone and
      # the buffers hold the parent's records, which the parent will send.
      def check_fork
        return if @pid == Process.pid

        @pid = Process.pid
        @log_buf.clear
        @span_buf.clear
        @metrics.clear
        @metric_start = Time.now.to_f
        @tick_cv = ConditionVariable.new
        start_ticker unless @closed
      end

      def normalize_level(level)
        l = level.to_s.downcase
        l = "warning" if l == "warn"
        LEVELS.include?(l) ? l : "error"
      end

      def symbolize(hash)
        return hash unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end

      def stringify(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v.is_a?(Symbol) ? v.to_s : v }
      end

      def escape(slug)
        slug.to_s.b.gsub(/[^a-zA-Z0-9_.~-]/) { |c| format("%%%02X", c.ord) }
      end

      def gzip(str)
        io = StringIO.new(+"")
        gz = Zlib::GzipWriter.new(io)
        gz.write(str)
        gz.close
        io.string
      end

      def hostname
        Socket.gethostname
      rescue StandardError
        nil
      end

      def safe_message(exception)
        exception.message.to_s
      rescue StandardError
        exception.class.to_s
      end

      def safe_inspect(value)
        value.inspect
      rescue StandardError
        value.class.to_s
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def debug(msg)
        return unless @config.debug

        @config.debug_output&.puts("[argus] #{msg}")
      rescue StandardError
        nil
      end
    end
  end
end
