# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"
require "tmpdir"
require "fileutils"

# Boots a real, minimal Rails app in a child process with nothing but
# `require "naijacloud/argus"` and ARGUS_DSN, the way `bundle add` sets it up,
# and checks what reaches the stub ingest. Skipped when Rails is not
# installed: the gem has no Rails dependency, so the default suite (and CI)
# does not install it. Run it with Rails on GEM_PATH.
class RailsTest < ArgusTest
  APP = <<~'RUBY'
    require "logger" # Rails 7.0/7.1 with concurrent-ruby 1.3.5 need it loaded first
    require "rails"
    require "action_controller/railtie"
    require "active_job/railtie"
    require "naijacloud/argus"

    class ArgusRailsApp < Rails::Application
      config.root = __dir__
      config.eager_load = false
      config.logger = Logger.new(nil)
      config.secret_key_base = "x" * 64
      config.hosts.clear
      config.active_support.to_time_preserves_timezone = :zone if config.active_support.respond_to?(:to_time_preserves_timezone=)
      config.active_job.queue_adapter = :inline
      config.action_dispatch.show_exceptions = Rails.gem_version >= Gem::Version.new("7.1") ? :all : true
      routes.append do
        get "/orders/:id" => "orders#show"
        get "/boom" => "orders#boom"
      end
    end

    class OrdersController < ActionController::Base
      def show
        NaijaCloud::Argus.set_user(id: "u_#{params[:id]}")
        render plain: "order #{params[:id]}"
      end

      def boom
        raise ArgumentError, "controller exploded"
      end
    end

    class FailingJob < ActiveJob::Base
      def perform(n)
        raise KeyError, "job #{n} failed"
      end
    end

    Rails.application.initialize!
    abort "not initialized" unless NaijaCloud::Argus.enabled?
    abort "middleware missing" unless Rails.application.middleware.middlewares.first == NaijaCloud::Argus::Rack

    env = ->(path) { Rack::MockRequest.env_for(path, "HTTP_HOST" => "shop.ng") }
    status, = Rails.application.call(env.call("/orders/42?token=abc"))
    abort "show returned #{status}" unless status == 200
    status, = Rails.application.call(env.call("/boom"))
    abort "boom returned #{status}" unless status == 500
    begin
      FailingJob.perform_now(7)
    rescue KeyError
      nil
    end
    Rails.error.handle(context: { order_id: 1 }) { raise IOError, "handled one" } if Rails.error.respond_to?(:handle)
    puts "rails=#{Rails.version}"
    puts "env=#{NaijaCloud::Argus.client.config.environment} service=#{NaijaCloud::Argus.client.config.service_name}"
    NaijaCloud::Argus.flush(5)
  RUBY

  def rails_available?
    system(RbConfig.ruby, "-e", 'require "rails"; require "active_job"', out: File::NULL, err: File::NULL)
  end

  def test_rails_app
    skip "Rails is not installed (the gem does not depend on it)" unless rails_available?

    dir = Dir.mktmpdir("argus-rails")
    File.write(File.join(dir, "app.rb"), APP)
    lib = File.expand_path("../lib", __dir__)
    env = { "ARGUS_DSN" => @server.dsn, "RAILS_ENV" => "test" }
    out = IO.popen([env, RbConfig.ruby, "-I", lib, File.join(dir, "app.rb"), { err: %i[child out] }], &:read)
    assert $?.success?, out
    assert_includes out, "env=test", "the Railtie uses Rails.env when no ARGUS_ENVIRONMENT is set"
    assert_includes out, "service=argus_rails_app"

    events = @server.wait_for(3, "/api/").map { |r| event_from(r) }
    by_value = events.to_h { |e| [e["exception"]["values"].last["value"], e] }

    boom = by_value.fetch("controller exploded")
    assert_equal "GET /boom", boom["transaction"]
    assert_equal "/boom", boom["request"]["url"].sub(%r{\Ahttps?://[^/]+}, "")

    job = by_value.fetch("job 7 failed")
    assert_equal "FailingJob", job["transaction"]
    assert_equal "FailingJob", job["contexts"]["job"]["class"]

    if by_value.key?("handled one")
      assert_equal "true", by_value["handled one"]["tags"]["handled"]
    end
    assert_equal 1, events.count { |e| e["exception"]["values"].last["value"] == "controller exploded" },
                 "reported once though Rack and Rails.error both saw it"

    spans = @server.wait_for(1, "/v1/traces").flat_map { |r| json(r)["resourceSpans"][0]["scopeSpans"][0]["spans"] }
    # Rails 7.1+ puts the route template in the env; before that the span is
    # named by controller and action.
    modern = out[/rails=(\S+)/, 1].to_s >= "7.1"
    show = spans.find { |s| s["name"] == (modern ? "GET /orders/:id" : "orders#show") }
    refute_nil show, spans.map { |s| s["name"] }.inspect
    attrs = otlp_attrs(show["attributes"])
    assert_equal "/orders/:id", attrs["http.route"] if modern
    assert_equal "200", attrs["http.response.status_code"]
    assert(spans.any? { |s| s["name"] == "FailingJob" && s["status"]["code"] == 2 })
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
