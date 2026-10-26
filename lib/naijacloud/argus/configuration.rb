# frozen_string_literal: true

module NaijaCloud
  module Argus
    # Options for `NaijaCloud::Argus.init`. Every option can be passed as a
    # keyword or set in the block:
    #
    #   NaijaCloud::Argus.init(dsn: "...", release: "1.4.2")
    #   NaijaCloud::Argus.init { |c| c.traces_sample_rate = 0.2 }
    class Configuration
      # Exceptions that describe a client's mistake rather than a bug. Matched
      # by name so the gem does not have to load Rails to know them.
      DEFAULT_EXCLUDED = %w[
        ActionController::RoutingError
        ActionController::UnknownFormat
        ActionController::BadRequest
        ActionController::ParameterMissing
        ActionController::InvalidAuthenticityToken
        ActionDispatch::Http::MimeNegotiation::InvalidType
        ActiveRecord::RecordNotFound
        AbstractController::ActionNotFound
        Sinatra::NotFound
      ].freeze

      OPTIONS = %i[
        dsn release environment service_name server_name sample_rate
        traces_sample_rate send_default_pii max_breadcrumbs before_send
        before_breadcrumb debug enabled project_root context_lines
        excluded_exceptions trace_propagation net_http rails_logs
        capture_at_exit debug_output
      ].freeze

      attr_accessor(*OPTIONS)

      def initialize(**options)
        @dsn = nil
        @release = nil
        @environment = nil
        @service_name = nil
        @server_name = nil
        @sample_rate = 1.0
        @traces_sample_rate = 1.0
        @send_default_pii = false
        @max_breadcrumbs = 100
        @before_send = nil
        @before_breadcrumb = nil
        @debug = false
        @enabled = true
        @project_root = nil
        @context_lines = true
        @excluded_exceptions = DEFAULT_EXCLUDED.dup
        @trace_propagation = true
        @net_http = true
        @rails_logs = false
        @capture_at_exit = true
        @debug_output = $stderr
        options.each do |key, value|
          # A typo in an option must not stop the app booting; say so instead.
          unless OPTIONS.include?(key.to_sym)
            warn("[argus] unknown option #{key.inspect} ignored")
            next
          end

          public_send("#{key}=", value)
        end
      end

      # Spec §1: the explicit option wins, then ARGUS_*, then SENTRY_*.
      def resolve!(env = ENV)
        @dsn = first(@dsn, env["ARGUS_DSN"], env["SENTRY_DSN"])
        @release = first(@release, env["ARGUS_RELEASE"], env["SENTRY_RELEASE"])
        @environment = first(@environment, env["ARGUS_ENVIRONMENT"], env["SENTRY_ENVIRONMENT"], "production")
        @service_name = first(@service_name, env["ARGUS_SERVICE_NAME"], env["OTEL_SERVICE_NAME"], "app")
        @debug ||= %w[1 true yes].include?(env["ARGUS_DEBUG"].to_s.downcase)
        self
      end

      def inspect
        "#<NaijaCloud::Argus::Configuration environment=#{@environment.inspect} release=#{@release.inspect}>"
      end

      private

      def first(*values)
        values.each do |v|
          next if v.nil?

          s = v.to_s.strip
          return s unless s.empty?
        end
        nil
      end
    end
  end
end
