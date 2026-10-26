# frozen_string_literal: true

require_relative "test_helper"

class OtlpTest < ArgusTest
  def resource_of(body, key)
    otlp_attrs(body[key].first["resource"]["attributes"])
  end

  def test_logs_shape
    client = build_client(release: "2.0.0", environment: "staging", service_name: "shop")
    client.log(:info, "order placed", order_id: "ord_81", total: 18_500, paid: true, ratio: 0.5, password: "x")
    client.log(:warning, "token abcdefghijkl leaked")
    assert client.flush(3)
    req = @server.requests_to("/v1/logs").last
    assert_equal "Bearer #{TEST_KEY}", req[:headers]["authorization"]
    assert_equal "application/json", req[:headers]["content-type"]
    body = json(req)

    res = resource_of(body, "resourceLogs")
    assert_equal "shop", res["service.name"]
    assert_equal "2.0.0", res["service.version"]
    assert_equal "staging", res["deployment.environment"]
    assert_equal "argus.ruby", res["telemetry.sdk.name"]
    assert_equal NaijaCloud::Argus::VERSION, res["telemetry.sdk.version"]
    assert_equal "argus.sdk/1", res["argus.contract"]

    records = body["resourceLogs"].first["scopeLogs"].first["logRecords"]
    first, second = records
    assert_equal 9, first["severityNumber"]
    assert_equal "INFO", first["severityText"]
    assert_equal "order placed", first["body"]["stringValue"]
    assert_match(/\A\d{19}\z/, first["timeUnixNano"])
    attrs = first["attributes"].to_h { |kv| [kv["key"], kv["value"]] }
    assert_equal({ "stringValue" => "ord_81" }, attrs["order_id"])
    assert_equal({ "intValue" => "18500" }, attrs["total"])
    assert_equal({ "boolValue" => true }, attrs["paid"])
    assert_equal({ "doubleValue" => 0.5 }, attrs["ratio"])
    assert_equal({ "stringValue" => "[Filtered]" }, attrs["password"])
    assert_equal 13, second["severityNumber"]
    assert_equal "token [Filtered] leaked", second["body"]["stringValue"]
    refute first.key?("traceId")
  end

  def test_logs_inside_a_span_carry_its_ids
    client = build_client
    span_ids = client.trace("work") { |s| client.log(:error, "inside"); [s.trace_id, s.span_id] }
    client.flush(3)
    rec = json(@server.requests_to("/v1/logs").last)["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]
    assert_equal span_ids, [rec["traceId"], rec["spanId"]]
  end

  def test_unknown_severity_is_ignored
    client = build_client
    client.log(:shout, "x")
    client.flush(1)
    assert_empty @server.requests_to("/v1/logs")
  end

  def test_metrics_shape
    client = build_client
    client.count("orders.placed", 1, method: "card")
    client.count("orders.placed", 2, method: "card")
    client.count("orders.placed", 1, method: "transfer")
    client.gauge("queue.depth", 4)
    client.gauge("queue.depth", 7)
    [3, 30, 3000, 20_000].each { |v| client.distribution("checkout.ms", v, nil, "ms") }
    client.count("bad", Float::NAN)
    assert client.flush(3)
    metrics = json(@server.requests_to("/v1/metrics").last)["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]

    sums = metrics.select { |m| m["name"] == "orders.placed" }
    assert_equal 2, sums.length
    card = sums.find { |m| otlp_attrs(m["sum"]["dataPoints"][0]["attributes"])["method"] == "card" }
    assert_equal 1, card["sum"]["aggregationTemporality"], "counters are delta"
    assert card["sum"]["isMonotonic"]
    assert_equal 3.0, card["sum"]["dataPoints"][0]["asDouble"]

    gauge = metrics.find { |m| m["name"] == "queue.depth" }
    assert_equal 7.0, gauge["gauge"]["dataPoints"][0]["asDouble"]

    hist = metrics.find { |m| m["name"] == "checkout.ms" }
    assert_equal "ms", hist["unit"]
    point = hist["histogram"]["dataPoints"][0]
    assert_equal "4", point["count"]
    assert_equal 23_033.0, point["sum"]
    assert_equal 3.0, point["min"]
    assert_equal 20_000.0, point["max"]
    assert_equal NaijaCloud::Argus::Client::HIST_BOUNDS, point["explicitBounds"]
    assert_equal %w[1 0 0 1 0 0 0 0 0 1 0 1], point["bucketCounts"]
    refute(metrics.any? { |m| m["name"] == "bad" })
  end

  def test_metrics_reset_after_each_flush_delta
    client = build_client
    client.count("c", 5)
    client.flush(3)
    client.count("c", 1)
    client.flush(3)
    reqs = @server.requests_to("/v1/metrics")
    values = reqs.map { |r| json(r)["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]["sum"]["dataPoints"][0]["asDouble"] }
    assert_equal [5.0, 1.0], values
  end

  def test_spans_shape_and_nesting
    client = build_client
    client.trace("parent", "job.kind" => "nightly") do
      client.trace("child") { |s| s.set_attribute("url.full", "https://x.ng/a") }
    end
    begin
      client.trace("failing") { raise ArgumentError, "bad" }
    rescue ArgumentError
      nil
    end
    assert client.flush(3)
    spans = json(@server.requests_to("/v1/traces").last)["resourceSpans"][0]["scopeSpans"][0]["spans"]
    parent = spans.find { |s| s["name"] == "parent" }
    child = spans.find { |s| s["name"] == "child" }
    failing = spans.find { |s| s["name"] == "failing" }

    assert_match(/\A\h{32}\z/, parent["traceId"])
    assert_match(/\A\h{16}\z/, parent["spanId"])
    refute parent.key?("parentSpanId")
    assert_equal parent["traceId"], child["traceId"]
    assert_equal parent["spanId"], child["parentSpanId"]
    assert_equal 1, parent["kind"]
    assert_operator parent["endTimeUnixNano"].to_i, :>=, parent["startTimeUnixNano"].to_i
    assert_equal({ "code" => 1 }, parent["status"])
    assert_equal({ "code" => 2, "message" => "ArgumentError: bad" }, failing["status"])
    assert_equal "nightly", otlp_attrs(parent["attributes"])["job.kind"]
    refute_equal parent["traceId"], failing["traceId"]
  end

  def test_module_level_attributes_as_a_braceless_hash
    init_argus
    NaijaCloud::Argus.trace("a", "job.kind" => "x", count: 2) { nil }
    NaijaCloud::Argus.start_span("b", "k" => 1).finish
    NaijaCloud::Argus.flush(3)
    names = @server.requests_to("/v1/traces").flat_map { |r| json(r)["resourceSpans"][0]["scopeSpans"][0]["spans"] }.map { |s| s["name"] }
    assert_equal %w[a b], names.sort
  end

  def test_traceparent_round_trip
    span = NaijaCloud::Argus::Span.new(nil, "x")
    parsed = NaijaCloud::Argus::Span.parse_traceparent(span.traceparent)
    assert_equal span.trace_id, parsed[:trace_id]
    assert_equal span.span_id, parsed[:span_id]
    assert_nil NaijaCloud::Argus::Span.parse_traceparent("00-#{'0' * 32}-#{'1' * 16}-01")
    assert_nil NaijaCloud::Argus::Span.parse_traceparent("garbage")
    assert_equal true, NaijaCloud::Argus::Span.parse_traceparent("00-#{'a' * 32}-#{'b' * 16}-01")[:sampled]
  end

  def test_an_unsampled_parent_records_nothing
    client = build_client
    parent = { trace_id: "a" * 32, span_id: "b" * 16, sampled: false }
    client.trace("x", nil, NaijaCloud::Argus::Span::KIND_INTERNAL, parent) { nil }
    client.flush(1)
    assert_empty @server.requests_to("/v1/traces")
  end

  def test_traces_sample_rate_zero
    client = build_client(traces_sample_rate: 0)
    client.trace("x") { nil }
    client.flush(1)
    assert_empty @server.requests_to("/v1/traces")
  end

  def test_big_batches_are_split_under_the_body_limit
    client = build_client
    # The spec's 1 MB queue bound would drop the oldest chunk before the
    # worker picks it up; this test is about the split, not the bound.
    client.transport.max_bytes = 16 << 20
    1200.times { |i| client.log(:info, "line #{i} #{'x' * 1500}") }
    assert client.flush(5)
    reqs = @server.requests_to("/v1/logs")
    assert_operator reqs.length, :>=, 3
    reqs.each { |r| assert_operator r[:body].bytesize, :<=, NaijaCloud::Argus::Client::MAX_BODY }
    total = reqs.sum { |r| json(r)["resourceLogs"][0]["scopeLogs"][0]["logRecords"].length }
    assert_equal 1200, total
  end

  def test_the_ticker_sends_logs_without_a_flush
    client = build_client
    client.log(:info, "later")
    reqs = @server.wait_for(1, "/v1/logs", timeout: 8)
    assert_equal 1, reqs.length
  end
end
