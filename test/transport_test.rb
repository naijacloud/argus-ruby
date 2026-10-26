# frozen_string_literal: true

require_relative "test_helper"

class TransportTest < ArgusTest
  T = NaijaCloud::Argus::Transport

  def setup
    super
    @debug = []
    @transport = T.new(debug: ->(m) { @debug << m })
    @slept = []
    @transport.sleeper = ->(s) { @slept << s }
  end

  def teardown
    @transport.close
    super
  end

  def req(body = "x", path = "/v1/logs")
    T::Request.new("http://127.0.0.1:#{@server.port}#{path}", body, { "Content-Type" => "text/plain" })
  end

  def test_sends_and_flushes
    assert @transport.enqueue("logs", req("hello"))
    assert @transport.flush(3)
    assert_equal "hello", @server.requests.last[:body]
    assert_equal "argus.ruby/#{NaijaCloud::Argus::VERSION}", @server.requests.last[:headers]["user-agent"]
  end

  def test_5xx_backs_off_exponentially_and_stops_after_five_tries
    6.times { @server.enqueue(status: 503) }
    @transport.enqueue("logs", req)
    assert @transport.flush(3)
    assert_equal 5, @server.requests.length
    assert_equal [1, 2, 4, 8], @slept
  end

  def test_backoff_is_capped_at_60_seconds
    assert_equal 60, [T::MAX_BACKOFF, 2**10].min
  end

  def test_recovers_after_a_5xx
    @server.enqueue(status: 500)
    @transport.enqueue("logs", req)
    assert @transport.flush(3)
    assert_equal 2, @server.requests.length
    assert_equal [1], @slept
  end

  def test_network_errors_retry_and_never_raise
    r = T::Request.new("http://127.0.0.1:#{closed_port}/v1/logs", "x", {})
    assert @transport.enqueue("logs", r)
    assert @transport.flush(5)
    assert_equal [1, 2, 4, 8], @slept
    assert(@debug.any? { |m| m.include?("network error") })
  end

  def test_429_waits_retry_after_and_retries_without_counting_a_try
    @server.enqueue(status: 429, headers: { "Retry-After" => "7" })
    @server.enqueue(status: 429, headers: { "X-Sentry-Rate-Limits" => "12:error;default:organization" })
    4.times { @server.enqueue(status: 500) }
    @transport.enqueue("errors", req)
    assert @transport.flush(3)
    assert_equal 7, @server.requests.length, "two 429s, then five counted tries"
    assert_equal [7.0, 12.0, 1, 2, 4, 8], @slept
  end

  def test_retry_after_parsing
    assert_equal 30.0, T.retry_after({ "retry-after" => "30" })
    assert_equal 60, T.retry_after({})
    assert_equal 1, T.retry_after({ "retry-after" => "0.1" })
    assert_equal 3600, T.retry_after({ "retry-after" => "99999" })
    assert_equal 5.0, T.retry_after({ "x-sentry-rate-limits" => "5:error:organization" })
  end

  def test_401_stops_the_lane_until_restart
    @server.enqueue(status: 401)
    @transport.enqueue("traces", req)
    assert @transport.flush(3)
    assert @transport.dead?("traces")
    refute @transport.enqueue("traces", req)
    assert @transport.enqueue("logs", req), "other lanes keep going"
    assert @transport.flush(3)
    assert_equal 2, @server.requests.length
  end

  def test_403_stops_the_lane_too
    @server.enqueue(status: 403)
    @transport.enqueue("logs", req)
    @transport.flush(3)
    assert @transport.dead?("logs")
  end

  def test_other_4xx_and_3xx_are_dropped_without_retry
    @server.enqueue(status: 400)
    @server.enqueue(status: 413)
    @server.enqueue(status: 301, headers: { "Location" => "http://evil.example/" })
    3.times { @transport.enqueue("logs", req) }
    assert @transport.flush(3)
    assert_equal 3, @server.requests.length
    assert_empty @slept
    refute @transport.dead?("logs")
  end

  def test_the_queue_is_bounded_and_drops_the_oldest
    @server.enqueue(status: 200, hang: 0.5)
    @transport.enqueue("logs", req("first"))
    sleep 0.1 # the first is in flight
    150.times { |i| @transport.enqueue("logs", req("item #{i}")) }
    assert @transport.flush(10)
    bodies = @server.requests.map { |r| r[:body] }
    assert_equal 1 + T::MAX_ITEMS, bodies.length
    assert_equal "item 50", bodies[1]
    assert_equal "item 149", bodies.last
  end

  def test_the_queue_is_bounded_by_bytes
    @server.enqueue(status: 200, hang: 0.5)
    @transport.enqueue("logs", req("first"))
    sleep 0.1
    5.times { |i| @transport.enqueue("logs", req("#{i}" + ("x" * 400_000))) }
    assert @transport.flush(10)
    assert_equal 3, @server.requests.length, "only the newest two fit in 1 MiB"
    refute @transport.enqueue("logs", req("y" * (T::MAX_BYTES + 1)))
  end

  def test_flush_times_out_when_the_server_hangs
    @server.enqueue(status: 200, hang: 2)
    @transport.enqueue("logs", req)
    refute @transport.flush(0.3)
  end

  def test_dropped_series_is_logged_once
    2.times { @server.enqueue(status: 200, headers: { "X-Argus-Dropped-Series" => "3" }) }
    2.times { @transport.enqueue("metrics", req) }
    @transport.flush(3)
    assert_equal 1, @debug.count { |m| m.include?("series limit") }
  end

  def test_it_keeps_working_in_a_forked_child
    skip "fork is not available" unless Process.respond_to?(:fork)

    @transport.enqueue("logs", req("parent"))
    @transport.flush(3)
    pid = fork do
      ok = @transport.enqueue("logs", req("child")) && @transport.flush(3)
      exit!(ok ? 0 : 1)
    end
    Process.wait(pid)
    assert_equal 0, $?.exitstatus
    assert_includes @server.requests.map { |r| r[:body] }, "child"
  end

  def test_after_close_nothing_is_accepted
    @transport.close
    refute @transport.enqueue("logs", req)
  end
end
