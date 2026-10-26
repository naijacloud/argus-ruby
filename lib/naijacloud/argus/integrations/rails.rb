# frozen_string_literal: true

module NaijaCloud
  module Argus
    module Integrations
      # Reports errors from Rails' error reporter (Rails 7.0+): unhandled
      # request and job errors, and anything an app passes to
      # `Rails.error.report` / `Rails.error.handle`.
      class ErrorSubscriber
        def report(error, handled:, severity: :error, context: {}, source: nil)
          client = Argus.client
          return unless client&.enabled?

          tags = { "handled" => handled.to_s, "mechanism" => "rails.error" }
          tags["source"] = source.to_s if source
          client.capture_exception(error, level: severity, tags: tags, extra: context.is_a?(Hash) ? context : nil)
        rescue StandardError
          nil
        end
      end

      # ActiveJob: each perform gets its own scope and span, and a failure is
      # reported with the job's class, id and queue. The exception is
      # re-raised, so retry_on / discard_on behave as before.
      module ActiveJob
        def self.included(base)
          base.around_perform do |job, block|
            NaijaCloud::Argus::Integrations::ActiveJob.around(job) { block.call }
          end
        end

        def self.around(job)
          client = Argus.client
          return yield unless client&.enabled?

          name = job.class.name.to_s
          client.with_scope do |scope|
            scope.transaction = name
            scope.set_tag("job.queue", job.queue_name) if job.respond_to?(:queue_name)
            scope.set_context("job", {
              class: name,
              job_id: job.job_id,
              queue: (job.queue_name if job.respond_to?(:queue_name)),
              executions: (job.executions if job.respond_to?(:executions)),
              provider_job_id: (job.provider_job_id if job.respond_to?(:provider_job_id)),
            })
            attrs = { "messaging.system" => "active_job", "job.id" => job.job_id }
            attrs["messaging.destination.name"] = job.queue_name if job.respond_to?(:queue_name)
            begin
              client.trace(name, attrs) { yield }
            rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised
              client.capture_exception(e, tags: { mechanism: "active_job" }) unless e.is_a?(SignalException)
              raise
            end
          end
        end
      end

      module RailsSetup
        module_function

        # Called after the app's own initializers, so an explicit
        # `NaijaCloud::Argus.init` in config/initializers wins.
        def start(app)
          unless Argus.initialized?
            options = { project_root: ::Rails.root.to_s }
            # Spec §1 defaults the environment to "production". A Rails app
            # knows better than that when nothing was set.
            if blank?(ENV["ARGUS_ENVIRONMENT"]) && blank?(ENV["SENTRY_ENVIRONMENT"])
              options[:environment] = ::Rails.env.to_s
            end
            if blank?(ENV["ARGUS_SERVICE_NAME"]) && blank?(ENV["OTEL_SERVICE_NAME"])
              options[:service_name] = app_name(app)
            end
            Argus.init(**options)
          end
          attach_logs if Argus.client&.config&.rails_logs && Argus.enabled?
        rescue StandardError => e
          warn("[argus] Rails setup failed: #{e.class}: #{e.message}")
        end

        def attach_logs
          sink = Argus::Logger.new(level: ::Rails.logger.level)
          if ::Rails.logger.respond_to?(:broadcast_to)
            ::Rails.logger.broadcast_to(sink)
          elsif defined?(::ActiveSupport::Logger) && ::ActiveSupport::Logger.respond_to?(:broadcast)
            ::Rails.logger.extend(::ActiveSupport::Logger.broadcast(sink))
          end
        end

        # `Shop::Application` -> "shop"; a top-level `ShopApp` -> "shop_app".
        def app_name(app)
          klass = app.class
          parent = klass.module_parent_name if klass.respond_to?(:module_parent_name)
          parent ||= klass.name.to_s.split("::").first.to_s.sub(/Application\z/, "")
          name = parent.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
          name.empty? ? nil : name
        rescue StandardError
          nil
        end

        def blank?(value)
          value.nil? || value.strip.empty?
        end
      end
    end

    # `bundle add naijacloud-argus` plus `ARGUS_DSN` is the whole Rails setup.
    class Railtie < ::Rails::Railtie
      initializer "naijacloud_argus.middleware" do |app|
        # First in the stack, so the request span covers every other
        # middleware and the scope is open before anything can fail.
        app.config.middleware.insert(0, NaijaCloud::Argus::Rack)
      end

      initializer "naijacloud_argus.active_job" do
        ActiveSupport.on_load(:active_job) { include NaijaCloud::Argus::Integrations::ActiveJob }
      end

      initializer "naijacloud_argus.error_subscriber" do
        if ::Rails.respond_to?(:error) && ::Rails.error.respond_to?(:subscribe)
          ::Rails.error.subscribe(NaijaCloud::Argus::Integrations::ErrorSubscriber.new)
        end
      end

      config.after_initialize do |app|
        NaijaCloud::Argus::Integrations::RailsSetup.start(app)
      end
    end
  end
end
