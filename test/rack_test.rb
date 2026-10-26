# frozen_string_literal: true

require_relative "test_helper"

class RackTest < ArgusTest
  def env_for(path, method: "GET", headers: {})
    path_info, query = path.split("?", 2)
    {
      "REQUEST_METHOD" => method, "PATH_INFO" => path_info, "QUERY_STRING" => query.to_s,
      "SCRIPT_NAME" => "", "SERVER_NAME" => "shop.ng", "SERVER_PORT" => "443",
      "HTTP_HOST" => "shop.ng", "rack.url_scheme" => "https", "REMOTE_ADDR" => "9.9.9.9",
      "HTTP_COOKIE" => "session=abc", "HTTP_AUTHORIZATION" => "Bearer abcdefghijk",
      "HTTP_USER_AGENT" => "curl/8",
    }.merge(headers)
  end

  def spans
    NaijaCloud::Argus.flush(3)
    @server.requests_to("/v1/traces").flat_map { |r| json(r)["resourceSpans"][0]["scopeSpans"][0]["spans"] }
  end

  def events
    @server.requests_to("/api/").map { |r| event_from(r) }
  end

  def test_server_span_named_by_the_route
    init_argus
    app = lambda do |env|
      env["action_dispatch.route_uri_pattern"] = "/users/:id(.:format)"
      [200, { "content-type" => "text/plain" }, ["ok"]]
    end
    status, _, body = NaijaCloud::Argus::Rack.new(app).call(env_for("/users/42?token=secret"))
    assert_equal 200, status
    assert_equal ["ok"], body

    span = spans.last
    assert_equal "GET /users/:id", span["name"]
    assert_equal 2, span["kind"]
    attrs = otlp_attrs(span["attributes"])
    assert_equal "GET", attrs["http.request.method"]
    assert_equal "/users/:id", attrs["http.route"]
    assert_equal "200", attrs["http.response.status_code"]
    assert_equal "https://shop.ng/users/42", attrs["url.full"], "no query string"
  end

  def test_sinatra_route
    init_argus
    app = lambda do |env|
      env["sinatra.route"] = "GET /orders/:id"
      [200, {}, []]
    end
    NaijaCloud::Argus::Rack.new(app).call(env_for("/orders/9"))
    assert_equal "GET /orders/:id", spans.last["name"]
  end

  def test_continues_the_callers_trace
    init_argus
    trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
    parent = "00f067aa0ba902b7"
    inner = nil
    app = lambda do |_env|
      inner = NaijaCloud::Argus.current_span
      [204, {}, []]
    end
    NaijaCloud::Argus::Rack.new(app).call(env_for("/", headers: { "HTTP_TRACEPARENT" => "00-#{trace_id}-#{parent}-01" }))
    assert_equal trace_id, inner.trace_id
    span = spans.last
    assert_equal trace_id, span["traceId"]
    assert_equal parent, span["parentSpanId"]
  end

  def test_unhandled_exception_is_reported_with_the_request_and_reraised
    init_argus
    app = lambda do |env|
      NaijaCloud::Argus.set_user(id: "u_7")
      env["action_dispatch.route_uri_pattern"] = "/checkout(.:format)"
      raise "kaboom"
    end
    assert_raises(RuntimeError) { NaijaCloud::Argus::Rack.new(app).call(env_for("/checkout?card=1", method: "POST")) }

    span = spans.last
    assert_equal 2, span["status"]["code"]
    assert_equal "500", otlp_attrs(span["attributes"])["http.response.status_code"]

    event = events.last
    assert_equal "kaboom", event["exception"]["values"].last["value"]
    assert_equal "POST /checkout", event["transaction"]
    assert_equal "u_7", event["user"]["id"]
    assert_equal "rack", event["tags"]["mechanism"]
    req = event["request"]
    assert_equal "POST", req["method"]
    assert_equal "https://shop.ng/checkout", req["url"]
    assert_equal "curl/8", req["headers"]["User-Agent"]
    refute req["headers"].key?("Cookie"), "cookies are never sent"
    refute req["headers"].key?("Authorization")
    refute req.key?("env"), "no IP without send_default_pii"
  end

  def test_a_rendered_500_with_an_exception_in_the_env_is_reported
    init_argus
    app = lambda do |env|
      env["action_dispatch.exception"] = RuntimeError.new("rendered")
      [500, {}, ["error page"]]
    end
    status, = NaijaCloud::Argus::Rack.new(app).call(env_for("/x"))
    assert_equal 500, status
    NaijaCloud::Argus.flush(3)
    assert_equal "rendered", events.last["exception"]["values"].last["value"]
  end

  def test_a_rendered_404_is_not_reported
    init_argus
    app = lambda do |env|
      env["action_dispatch.exception"] = RuntimeError.new("not found")
      [404, {}, []]
    end
    NaijaCloud::Argus::Rack.new(app).call(env_for("/missing"))
    NaijaCloud::Argus.flush(3)
    assert_empty events
  end

  def test_the_request_scope_does_not_leak
    init_argus
    app = lambda do |_env|
      NaijaCloud::Argus.set_user(id: "in-request")
      [200, {}, []]
    end
    NaijaCloud::Argus::Rack.new(app).call(env_for("/"))
    NaijaCloud::Argus.capture_message("after")
    NaijaCloud::Argus.flush(3)
    assert_nil events.last["user"]
  end

  def test_without_a_dsn_it_just_calls_the_app
    NaijaCloud::Argus.init
    assert_equal [200, {}, ["ok"]], NaijaCloud::Argus::Rack.new(->(_) { [200, {}, ["ok"]] }).call(env_for("/"))
  end

  def test_rails_before_7_1_uses_controller_and_action
    init_argus
    app = lambda do |env|
      env["action_dispatch.request.path_parameters"] = { controller: "users", action: "show" }
      [200, {}, []]
    end
    NaijaCloud::Argus::Rack.new(app).call(env_for("/users/1"))
    assert_equal "users#show", spans.last["name"]
  end
end
