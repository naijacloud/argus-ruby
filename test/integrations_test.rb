# frozen_string_literal: true

require_relative "test_helper"
require "net/http"
require "rbconfig"

class IntegrationsTest < ArgusTest
  def spans
    NaijaCloud::Argus.flush(3)
    @server.requests_to("/v1/traces").flat_map { |r| json(r)["resourceSpans"][0]["scopeSpans"][0]["spans"] }
  end

  # ---- Net::HTTP ----

  def test_outgoing_net_http_gets_a_child_span_and_traceparent
    init_argus
    outer = nil
    NaijaCloud::Argus.trace("checkout") do |span|
      outer = span
      Net::HTTP.get_response(URI("http://127.0.0.1:#{@server.port}/downstream?token=abc"))
    end
    downstream = @server.requests_to("/downstream").last
    tp = NaijaCloud::Argus::Span.parse_traceparent(downstream[:headers]["traceparent"])
    assert_equal outer.trace_id, tp[:trace_id]

    all = spans
    client_span = all.find { |s| s["kind"] == 3 }
    assert_equal tp[:span_id], client_span["spanId"]
    assert_equal outer.span_id, client_span["parentSpanId"]
    attrs = otlp_attrs(client_span["attributes"])
    assert_equal "http://127.0.0.1:#{@server.port}/downstream", attrs["url.full"]
    assert_equal "200", attrs["http.response.status_code"]
  end

  def test_net_http_outside_a_span_leaves_a_breadcrumb_only
    init_argus
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@server.port}/plain?q=1"))
    assert_nil @server.requests_to("/plain").last[:headers]["traceparent"]
    NaijaCloud::Argus.capture_message("after")
    NaijaCloud::Argus.flush(3)
    crumb = event_from(@server.requests_to("/api/").last)["breadcrumbs"]["values"].last
    assert_equal "net.http", crumb["category"]
    assert_equal "http://127.0.0.1:#{@server.port}/plain", crumb["data"]["url"]
    assert_equal 200, crumb["data"]["status_code"]
  end

  def test_argus_own_requests_are_not_traced
    init_argus
    NaijaCloud::Argus.trace("t") { NaijaCloud::Argus.log.info("x") }
    NaijaCloud::Argus.flush(3)
    NaijaCloud::Argus.flush(3)
    @server.requests_to("/v1/").each { |r| assert_nil r[:headers]["traceparent"] }
    assert_equal 1, spans.length, "only the user's span, none for the SDK's own sends"
  end

  # ---- Logger ----

  def test_logger_sink
    init_argus
    logger = NaijaCloud::Argus::Logger.new(level: ::Logger::INFO, progname: "app")
    assert_kind_of ::Logger, logger
    logger.debug("dropped by level")
    logger.info("plain line")
    logger.warn { "from a block" }
    logger.error(RuntimeError.new("an error"))
    logger.info("\e[1m\e[32mcolored\e[0m")
    logger.add(::Logger::FATAL, nil, "progname as message")
    NaijaCloud::Argus.flush(3)
    recs = @server.requests_to("/v1/logs").flat_map { |r| json(r)["resourceLogs"][0]["scopeLogs"][0]["logRecords"] }
    assert_equal ["plain line", "from a block", "RuntimeError: an error", "colored", "progname as message"],
                 recs.map { |r| r["body"]["stringValue"] }
    assert_equal %w[INFO WARN ERROR INFO FATAL], recs.map { |r| r["severityText"] }
    assert_equal "app", otlp_attrs(recs.first["attributes"])["logger.name"]
  end

  def test_logger_without_init_is_harmless
    logger = NaijaCloud::Argus::Logger.new
    assert logger.info("nothing happens")
  end

  # ---- process exit ----

  def run_script(code)
    lib = File.expand_path("../lib", __dir__)
    out = IO.popen([RbConfig.ruby, "-I", lib, "-e", code, { err: %i[child out] }], &:read)
    [out, $?]
  end

  def test_uncaught_exception_at_exit_is_reported_and_flushed
    out, status = run_script(<<~RUBY)
      require "naijacloud/argus"
      NaijaCloud::Argus.init(dsn: #{@server.dsn.inspect})
      NaijaCloud::Argus.log.info("queued before the crash")
      raise ArgumentError, "crashed at boot"
    RUBY
    refute status.success?
    assert_includes out, "crashed at boot", "Ruby still prints the error"
    event = event_from(@server.wait_for(1, "/api/").last)
    assert_equal "crashed at boot", event["exception"]["values"].last["value"]
    assert_equal "fatal", event["level"]
    assert_equal "at_exit", event["tags"]["mechanism"]
    refute_empty @server.wait_for(1, "/v1/logs"), "queued logs are flushed at exit"
  end

  def test_a_normal_exit_is_not_reported
    _, status = run_script(<<~RUBY)
      require "naijacloud/argus"
      NaijaCloud::Argus.init(dsn: #{@server.dsn.inspect})
      NaijaCloud::Argus.metrics.count("runs")
      exit 0
    RUBY
    assert status.success?
    refute_empty @server.wait_for(1, "/v1/metrics")
    assert_empty @server.requests_to("/api/")
  end

  def test_never_raises_when_the_ingest_is_down
    NaijaCloud::Argus.init(dsn: "http://#{TEST_KEY}@127.0.0.1:#{closed_port}/7")
    NaijaCloud::Argus.client.transport.sleeper = ->(_) {}
    refute_nil NaijaCloud::Argus.capture_exception(RuntimeError.new("x"))
    NaijaCloud::Argus.log.error("x")
    NaijaCloud::Argus.cron.check_in("x")
    assert NaijaCloud::Argus.flush(5)
  end
end
