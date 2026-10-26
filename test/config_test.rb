# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < ArgusTest
  Dsn = NaijaCloud::Argus::Dsn

  def test_parses_a_dsn
    d = Dsn.parse("https://abc123@argus-in.naijacloud.com/41")
    assert_equal "abc123", d.public_key
    assert_equal "41", d.project_id
    assert_equal "https://argus-in.naijacloud.com", d.origin
    assert_equal "https://argus-in.naijacloud.com/api/41/envelope/", d.envelope_url
    assert_equal "https://argus-in.naijacloud.com/v1/logs", d.ingest_url("/v1/logs")
  end

  def test_keeps_a_path_prefix_and_a_port
    d = Dsn.parse("http://k@localhost:9000/argus/3")
    assert_equal "http://localhost:9000/argus", d.origin
    assert_equal "3", d.project_id
  end

  def test_rejects_what_is_not_a_dsn
    [nil, "", "   ", "not a url", "ftp://k@h/1", "https://h/1", "https://k@h/", "https://k@h/abc", 42].each do |raw|
      assert_nil Dsn.parse(raw), raw.inspect
    end
  end

  def test_inspect_does_not_show_the_key
    refute_includes Dsn.parse("https://secretkey@h.example/1").inspect, "secretkey"
  end

  def test_explicit_option_wins_over_environment
    ENV["ARGUS_DSN"] = "https://envkey@h/2"
    ENV["SENTRY_DSN"] = "https://sentry@h/3"
    c = NaijaCloud::Argus::Configuration.new(dsn: "https://opt@h/1").resolve!
    assert_equal "https://opt@h/1", c.dsn
  end

  def test_argus_env_wins_over_sentry_env
    ENV["ARGUS_DSN"] = "https://envkey@h/2"
    ENV["SENTRY_DSN"] = "https://sentry@h/3"
    ENV["SENTRY_RELEASE"] = "s-1"
    ENV["ARGUS_ENVIRONMENT"] = "staging"
    ENV["SENTRY_ENVIRONMENT"] = "qa"
    c = NaijaCloud::Argus::Configuration.new.resolve!
    assert_equal "https://envkey@h/2", c.dsn
    assert_equal "s-1", c.release
    assert_equal "staging", c.environment
  end

  def test_sentry_env_is_the_fallback_and_production_the_default
    ENV["SENTRY_DSN"] = "https://sentry@h/3"
    c = NaijaCloud::Argus::Configuration.new.resolve!
    assert_equal "https://sentry@h/3", c.dsn
    assert_equal "production", c.environment
    assert_nil c.release
  end

  def test_blank_values_count_as_unset
    ENV["ARGUS_DSN"] = "  "
    ENV["SENTRY_DSN"] = "https://sentry@h/3"
    assert_equal "https://sentry@h/3", NaijaCloud::Argus::Configuration.new(dsn: "").resolve!.dsn
  end

  def test_block_configuration
    client = init_argus { |c| c.release = "9.9.9" }
    assert_equal "9.9.9", client.config.release
    assert NaijaCloud::Argus.enabled?
  end

  def test_unknown_option_warns_and_does_not_raise
    _, err = capture_io { init_argus(not_an_option: true) }
    assert_includes err, "not_an_option"
    assert NaijaCloud::Argus.enabled?
  end

  def test_init_twice_returns_the_first_client
    first = init_argus
    assert_same first, NaijaCloud::Argus.init(dsn: "https://other@h/9")
  end

  def test_enabled_false_turns_it_off
    client = build_client(enabled: false)
    refute client.enabled?
  end

  def test_no_dsn_is_a_no_op_that_sends_nothing
    NaijaCloud::Argus.init
    refute NaijaCloud::Argus.enabled?
    assert_nil NaijaCloud::Argus.capture_exception(RuntimeError.new("x"))
    assert_nil NaijaCloud::Argus.capture_message("x")
    NaijaCloud::Argus.log.error("x")
    NaijaCloud::Argus.metrics.count("x")
    NaijaCloud::Argus.set_user(id: "1")
    NaijaCloud::Argus.add_breadcrumb(message: "x")
    NaijaCloud::Argus.cron.check_in("x", :start)
    assert_equal 5, NaijaCloud::Argus.trace("t") { |span| span.set_attribute("k", 1) && 5 }
    assert_equal :ran, NaijaCloud::Argus.cron.monitor("x") { :ran }
    assert_equal "dark", NaijaCloud::Argus.flags.variant("theme", "u1", "dark")
    assert_equal true, NaijaCloud::Argus.flags.on?("f", "u1", true)
    assert_equal({}, NaijaCloud::Argus.flags.all("u1"))
    assert NaijaCloud::Argus.flush
    sleep 0.1
    assert_empty @server.requests
  end

  def test_before_init_everything_is_safe
    assert_nil NaijaCloud::Argus.client
    assert_nil NaijaCloud::Argus.capture_exception(RuntimeError.new("x"))
    assert_equal 1, NaijaCloud::Argus.trace("t") { 1 }
    assert NaijaCloud::Argus.close
  end

  def test_an_invalid_dsn_is_a_no_op_and_says_so_in_debug
    out = StringIO.new
    client = build_client(dsn: "nonsense", debug: true, debug_output: out)
    refute client.enabled?
    assert_includes out.string, "DSN is not valid"
  end
end
