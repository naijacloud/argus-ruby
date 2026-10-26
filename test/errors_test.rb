# frozen_string_literal: true

require_relative "test_helper"

class ErrorsTest < ArgusTest
  class PaymentError < StandardError; end

  def capture_one(client, error, **ctx)
    id = client.capture_exception(error, **ctx)
    assert client.flush(3)
    [id, @server.requests_to("/api/").last]
  end

  def test_envelope_shape_and_auth
    client = build_client(release: "1.2.3", environment: "staging")
    id, req = capture_one(client, raise_and_rescue(PaymentError.new("card declined")))

    assert_match(/\A\h{32}\z/, id)
    assert_equal "POST", req[:method]
    assert_equal "/api/7/envelope/", req[:path]
    assert_equal "application/x-sentry-envelope", req[:headers]["content-type"]
    assert_equal "gzip", req[:headers]["content-encoding"]
    assert_includes req[:headers]["x-sentry-auth"], "sentry_key=#{TEST_KEY}"
    assert_includes req[:headers]["x-sentry-auth"], "sentry_version=7"
    assert_includes req[:headers]["x-sentry-auth"], "sentry_client=argus.ruby/#{NaijaCloud::Argus::VERSION}"
    refute_includes req[:path], TEST_KEY, "a server keeps the key out of the URL"

    header, item, event = envelope(req)
    assert_equal id, header["event_id"]
    assert_equal @server.dsn, header["dsn"]
    assert_equal({ "name" => "argus.ruby", "version" => NaijaCloud::Argus::VERSION }, header["sdk"])
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, header["sent_at"])
    assert_equal({ "type" => "event", "content_type" => "application/json" }, item)

    assert_equal id, event["event_id"]
    assert_equal "ruby", event["platform"]
    assert_equal "error", event["level"]
    assert_equal "1.2.3", event["release"]
    assert_equal "staging", event["environment"]
    assert_kind_of Float, event["timestamp"]
    assert_equal "argus.ruby", event["sdk"]["name"]
    assert_equal "ruby", event["contexts"]["runtime"]["name"]
    exc = event["exception"]["values"].last
    assert_equal "ErrorsTest::PaymentError", exc["type"]
    assert_equal "card declined", exc["value"]
  end

  def test_frames_are_oldest_first_with_context
    client = build_client(project_root: File.expand_path("..", __dir__))
    _, req = capture_one(client, raise_and_rescue(RuntimeError.new("boom")))
    frames = event_from(req)["exception"]["values"].last["stacktrace"]["frames"]
    last = frames.last
    assert_equal "test/test_helper.rb", last["filename"], "the raising frame is last"
    assert_match(/(\A|#)raise_and_rescue\z/, last["function"]) # 3.4 adds the class
    assert last["in_app"]
    assert_includes last["context_line"], "raise error"
    assert_kind_of Array, last["pre_context"]
    refute frames.first["in_app"], "minitest's own frames are not in_app"
  end

  def test_causes_come_first_and_the_error_last
    client = build_client
    error = begin
      begin
        raise ArgumentError, "root cause"
      rescue ArgumentError
        raise PaymentError, "wrapper"
      end
    rescue PaymentError => e
      e
    end
    _, req = capture_one(client, error)
    values = event_from(req)["exception"]["values"]
    assert_equal %w[ArgumentError ErrorsTest::PaymentError], values.map { |v| v["type"] }
  end

  def test_capture_message
    client = build_client
    client.capture_message("webhook signature mismatch", level: :warn, tags: { provider: "paystack" })
    client.flush(3)
    event = event_from(@server.requests_to("/api/").last)
    assert_equal "webhook signature mismatch", event["message"]
    assert_equal "warning", event["level"]
    assert_equal "paystack", event["tags"]["provider"]
    refute event.key?("exception")
  end

  def test_scope_user_tags_breadcrumbs_and_context
    client = build_client(max_breadcrumbs: 3)
    client.set_user(id: "u_1", email: "ada@example.com", ip_address: "1.2.3.4")
    client.set_tags(region: "af-west")
    client.set_context("order", { id: "ord_1" })
    5.times { |i| client.add_breadcrumb(category: "step", message: "crumb #{i}", data: { password: "x" }) }
    _, req = capture_one(client, RuntimeError.new("x"), extra: { order_id: 1, secret: "s" }, fingerprint: ["a", 1])
    event = event_from(req)

    assert_equal({ "id" => "u_1", "email" => "ada@example.com" }, event["user"], "no IP without send_default_pii")
    assert_equal "af-west", event["tags"]["region"]
    assert_equal({ "id" => "ord_1" }, event["contexts"]["order"])
    crumbs = event["breadcrumbs"]["values"]
    assert_equal ["crumb 2", "crumb 3", "crumb 4"], crumbs.map { |c| c["message"] }
    assert_equal "[Filtered]", crumbs.last["data"]["password"]
    assert_equal({ "order_id" => 1, "secret" => "[Filtered]" }, event["extra"])
    assert_equal %w[a 1], event["fingerprint"]
  end

  def test_send_default_pii_keeps_the_ip
    client = build_client(send_default_pii: true)
    client.set_user(id: "u", ip_address: "1.2.3.4")
    _, req = capture_one(client, RuntimeError.new("x"))
    assert_equal "1.2.3.4", event_from(req)["user"]["ip_address"]
  end

  def test_scopes_do_not_leak_between_threads
    client = build_client
    client.set_tag("global", "yes")
    t = Thread.new do
      client.with_scope do
        client.set_user(id: "thread-user")
        client.set_tag("local", "yes")
        client.capture_exception(RuntimeError.new("in thread"))
      end
    end
    t.join
    client.capture_exception(RuntimeError.new("outside"))
    client.flush(3)
    events = @server.requests_to("/api/").map { |r| event_from(r) }
    inside = events.find { |e| e["exception"]["values"].last["value"] == "in thread" }
    outside = events.find { |e| e["exception"]["values"].last["value"] == "outside" }
    assert_equal "thread-user", inside["user"]["id"]
    assert_equal({ "global" => "yes", "local" => "yes" }, inside["tags"])
    assert_nil outside["user"]
    assert_equal({ "global" => "yes" }, outside["tags"])
  end

  def test_before_send_can_change_or_drop
    client = build_client(before_send: lambda { |event|
      next nil if event[:exception][:values].last[:value] == "drop me"

      event[:tags] = { "changed" => "yes" }
      event
    })
    assert_nil client.capture_exception(RuntimeError.new("drop me"))
    client.capture_exception(RuntimeError.new("keep me"))
    client.flush(3)
    reqs = @server.requests_to("/api/")
    assert_equal 1, reqs.length
    assert_equal "yes", event_from(reqs.first)["tags"]["changed"]
  end

  def test_before_send_that_raises_sends_unchanged
    client = build_client(before_send: ->(_e) { raise "bug in hook" })
    refute_nil client.capture_exception(RuntimeError.new("x"))
    client.flush(3)
    assert_equal 1, @server.requests_to("/api/").length
  end

  def test_the_same_exception_is_sent_once
    client = build_client
    err = RuntimeError.new("once")
    refute_nil client.capture_exception(err)
    assert_nil client.capture_exception(err)
    client.flush(3)
    assert_equal 1, @server.requests_to("/api/").length
  end

  def test_sample_rate_zero_sends_nothing
    client = build_client(sample_rate: 0)
    assert_nil client.capture_exception(RuntimeError.new("x"))
  end

  def test_excluded_exceptions
    client = build_client(excluded_exceptions: ["ErrorsTest::PaymentError"])
    assert_nil client.capture_exception(PaymentError.new("x"))
    refute_nil client.capture_exception(RuntimeError.new("y"))
  end

  def test_messages_and_extra_are_scrubbed
    client = build_client
    _, req = capture_one(client, RuntimeError.new("login failed password=hunter2 card 4111111111111111"))
    value = event_from(req)["exception"]["values"].last["value"]
    refute_includes value, "hunter2"
    refute_includes value, "4111111111111111"
  end

  def test_event_inside_a_span_carries_trace_and_transaction
    client = build_client
    client.trace("checkout") { client.capture_exception(RuntimeError.new("x")) }
    client.flush(3)
    event = event_from(@server.requests_to("/api/").last)
    assert_equal "checkout", event["transaction"]
    assert_match(/\A\h{32}\z/, event["contexts"]["trace"]["trace_id"])
  end

  def test_non_exception_values
    client = build_client
    client.capture_exception("a string")
    client.flush(3)
    assert_includes event_from(@server.requests_to("/api/").last)["exception"]["values"].last["value"], "a string"
  end

  def test_frozen_exception_does_not_raise
    client = build_client
    refute_nil client.capture_exception(RuntimeError.new("frozen").freeze)
  end

  def test_exception_without_backtrace_has_no_stacktrace
    client = build_client
    _, req = capture_one(client, RuntimeError.new("never raised"))
    refute event_from(req)["exception"]["values"].last.key?("stacktrace")
  end

  def test_limits_tags_and_lengths
    client = build_client(release: "r" * 300)
    tags = (1..60).to_h { |i| ["t#{i}", i.to_s] }
    _, req = capture_one(client, RuntimeError.new("x"), tags: tags, transaction: "x" * 400)
    event = event_from(req)
    assert_equal 50, event["tags"].size
    assert_equal 200, event["release"].length
    assert_equal 300, event["transaction"].length
  end
end
