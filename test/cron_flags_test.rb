# frozen_string_literal: true

require_relative "test_helper"

class CronFlagsTest < ArgusTest
  def test_check_in_paths
    client = build_client
    client.check_in("nightly-invoices", :start)
    client.check_in("nightly-invoices", :ok)
    client.check_in("nightly-invoices", :error, "failed with password=hunter2")
    client.check_in("nightly-invoices", 3)
    client.check_in("with space/slash", :ok)
    assert client.flush(3)
    reqs = @server.requests_to("/v1/cron/")
    assert_equal %w[
      /v1/cron/nightly-invoices/start
      /v1/cron/nightly-invoices
      /v1/cron/nightly-invoices/fail
      /v1/cron/nightly-invoices/3
      /v1/cron/with%20space%2Fslash
    ], reqs.map { |r| r[:path] }
    assert_equal "Bearer #{TEST_KEY}", reqs.first[:headers]["authorization"]
    assert_equal "failed with password=[Filtered]", reqs[2][:body]
    assert_equal "", reqs[0][:body]
  end

  def test_output_is_cut_at_2kb
    client = build_client
    client.check_in("job", :ok, "x" * 5000)
    client.flush(3)
    assert_equal 2048, @server.requests_to("/v1/cron/").last[:body].bytesize
  end

  def test_monitor_block_reports_start_and_ok
    init_argus
    assert_equal 42, NaijaCloud::Argus.cron.monitor("sync") { 42 }
    NaijaCloud::Argus.flush(3)
    assert_equal %w[/v1/cron/sync/start /v1/cron/sync], @server.requests_to("/v1/cron/").map { |r| r[:path] }
  end

  def test_monitor_block_reports_failure_and_reraises
    init_argus
    assert_raises(KeyError) { NaijaCloud::Argus.monitor("sync") { raise KeyError, "missing" } }
    NaijaCloud::Argus.flush(3)
    reqs = @server.requests_to("/v1/cron/")
    assert_equal %w[/v1/cron/sync/start /v1/cron/sync/fail], reqs.map { |r| r[:path] }
    assert_equal "KeyError: missing", reqs.last[:body]
  end

  def test_unknown_monitor_404_is_dropped_quietly
    client = build_client
    @server.enqueue(status: 404)
    client.check_in("nope", :ok)
    assert client.flush(3)
    refute client.transport.dead?("crons")
  end

  def test_a_bad_status_never_raises_from_the_module_api
    init_argus
    assert_nil NaijaCloud::Argus.cron.check_in("x", :whatever)
  end

  # ---- flags ----

  def flags_response(flags)
    { status: 200, body: { "flags" => flags, "environment" => "production" } }
  end

  def test_flags_request_and_answers
    init_argus(environment: "staging")
    @server.enqueue(**flags_response("new-checkout" => "on", "theme" => "dark"))
    assert NaijaCloud::Argus.flags.on?("new-checkout", "u_1", false, plan: "pro")
    req = @server.requests_to("/v1/flags/evaluate").last
    assert_equal "Bearer #{TEST_KEY}", req[:headers]["authorization"]
    assert_equal({ "subject" => "u_1", "environment" => "staging", "attributes" => { "plan" => "pro" } }, json(req))

    assert_equal "dark", NaijaCloud::Argus.flags.variant("theme", "u_1", "light", plan: "pro")
    assert_equal "light", NaijaCloud::Argus.flags.variant("missing", "u_1", "light", plan: "pro")
    refute NaijaCloud::Argus.flags.on?("missing", "u_1", false, plan: "pro")
    assert NaijaCloud::Argus.flags.on?("missing", "u_1", true, plan: "pro")
    assert_equal 1, @server.requests_to("/v1/flags/").length, "answers are cached per subject"
  end

  def test_off_flag
    init_argus
    @server.enqueue(**flags_response("f" => "off"))
    refute NaijaCloud::Argus.flags.on?("f", "u", true)
  end

  def test_all
    init_argus
    @server.enqueue(**flags_response("a" => "on", "b" => "blue"))
    assert_equal({ "a" => "on", "b" => "blue" }, NaijaCloud::Argus.flags.all("u"))
  end

  def test_fallback_when_argus_fails
    init_argus
    @server.enqueue(status: 500, body: "oops")
    assert_equal "light", NaijaCloud::Argus.flags.variant("theme", "u", "light")
  end

  def test_fallback_when_unreachable
    NaijaCloud::Argus.init(dsn: "http://#{TEST_KEY}@127.0.0.1:#{closed_port}/7")
    assert_equal true, NaijaCloud::Argus.flags.on?("f", "u", true)
  end

  def test_fallback_on_a_slow_answer
    init_argus
    @server.enqueue(status: 200, body: { "flags" => { "f" => "on" } }, hang: 3)
    started = Time.now
    refute NaijaCloud::Argus.flags.on?("f", "u")
    assert_operator Time.now - started, :<, 2.8
  end

  def test_401_stops_flag_evaluation
    init_argus
    @server.enqueue(status: 401)
    refute NaijaCloud::Argus.flags.on?("f", "u1")
    refute NaijaCloud::Argus.flags.on?("f", "u2")
    assert_equal 1, @server.requests_to("/v1/flags/").length
  end

  def test_429_pauses_flag_evaluation
    init_argus
    @server.enqueue(status: 429, headers: { "Retry-After" => "60" })
    refute NaijaCloud::Argus.flags.on?("f", "u1")
    refute NaijaCloud::Argus.flags.on?("f", "u2")
    assert_equal 1, @server.requests_to("/v1/flags/").length
  end

  def test_empty_subject_is_not_sent
    init_argus
    assert_equal "x", NaijaCloud::Argus.flags.variant("f", "", "x")
    assert_empty @server.requests
  end
end
