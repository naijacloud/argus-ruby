# frozen_string_literal: true

module NaijaCloud
  module Argus
    # Rack middleware: a server span per request (continuing the caller's W3C
    # `traceparent`), named by the route once the router has matched it, and
    # unhandled exceptions reported with the request they came from.
    #
    #   use NaijaCloud::Argus::Rack            # config.ru, Sinatra, Hanami, Roda
    #
    # Rails does not need this line: the Railtie inserts it.
    class Rack
      # Headers worth seeing on an error. An allowlist, not a denylist: a
      # header nobody thought of is not sent. Cookie is never sent (spec §7).
      HEADERS = %w[
        HTTP_HOST HTTP_USER_AGENT HTTP_ACCEPT HTTP_ACCEPT_LANGUAGE HTTP_REFERER
        HTTP_X_REQUEST_ID HTTP_X_FORWARDED_PROTO HTTP_X_FORWARDED_HOST HTTP_TRACEPARENT
        CONTENT_TYPE CONTENT_LENGTH
      ].freeze

      # Where frameworks leave an exception they rendered as an error page
      # instead of letting it raise through us.
      EXCEPTION_KEYS = %w[action_dispatch.exception rack.exception sinatra.error].freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        client = Argus.client
        return @app.call(env) unless client&.enabled? && !env["naijacloud.argus.span"]

        client.with_scope { |scope| call_with(client, scope, env) }
      end

      # The route template for a request, once routing has happened:
      # "/users/:id", or nil when the framework does not say.
      def self.route(env)
        if (pattern = env["action_dispatch.route_uri_pattern"])
          return pattern.to_s.sub(/\(\.:format\)\z/, "")
        end
        if (sinatra = env["sinatra.route"])
          return sinatra.to_s.split(" ", 2).last
        end
        if (grape = env["grape.routing_args"]) && grape.is_a?(Hash) && (info = grape[:route_info])
          return info.path.to_s.sub(/\(\.:format\)\z/, "") if info.respond_to?(:path)
        end
        nil
      rescue StandardError
        nil
      end

      # "UsersController#show" for Rails before 7.1, where the URI pattern is
      # not in the env.
      def self.controller_action(env)
        params = env["action_dispatch.request.path_parameters"]
        return nil unless params.is_a?(Hash) && params[:controller] && params[:action]

        "#{params[:controller]}##{params[:action]}"
      end

      def self.url(env)
        scheme = env["HTTP_X_FORWARDED_PROTO"].to_s.split(",").first || env["rack.url_scheme"] || "http"
        host = env["HTTP_HOST"] || "#{env['SERVER_NAME']}:#{env['SERVER_PORT']}"
        "#{scheme.strip}://#{host}#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
      end

      private

      def call_with(client, scope, env)
        method = env["REQUEST_METHOD"].to_s
        path = "#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
        url = Scrub.strip_query(Rack.url(env))
        span = client.start_span(
          "#{method} #{path}",
          kind: Span::KIND_SERVER,
          parent: Span.parse_traceparent(env["HTTP_TRACEPARENT"]),
          attributes: { "http.request.method" => method, "url.full" => url, "url.path" => path,
                        "server.address" => env["HTTP_HOST"] || env["SERVER_NAME"] },
        )
        env["naijacloud.argus.span"] = span
        scope.request = request_info(client, env, method, url)
        scope.transaction = -> { name_for(env, method) }

        begin
          status, headers, body = Span.with(span) { @app.call(env) }
        rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised
          finish(span, env, method, 500)
          unless e.is_a?(SignalException) || e.is_a?(SystemExit)
            client.capture_exception(e, tags: { mechanism: "rack" }, transaction: name_for(env, method))
          end
          raise
        end

        status = status.to_i
        if status >= 500 && (err = EXCEPTION_KEYS.lazy.map { |k| env[k] }.find { |x| x.is_a?(Exception) })
          client.capture_exception(err, tags: { mechanism: "rack" }, transaction: name_for(env, method))
        end
        finish(span, env, method, status)
        [status, headers, body]
      end

      def finish(span, env, method, status)
        route = Rack.route(env)
        span.set_attribute("http.route", route) if route
        span.name = name_for(env, method)
        span.set_attribute("http.response.status_code", status)
        span.finish(status >= 500 ? "HTTP #{status}" : nil)
      rescue StandardError
        nil
      end

      def name_for(env, method)
        route = Rack.route(env)
        return "#{method} #{route}" if route

        Rack.controller_action(env) || "#{method} #{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
      end

      def request_info(client, env, method, url)
        headers = {}
        HEADERS.each do |key|
          next unless env[key]

          name = key.sub(/\AHTTP_/, "").split("_").map(&:capitalize).join("-")
          headers[name] = env[key].to_s
        end
        info = { method: method, url: url, headers: headers }
        info[:env] = { "REMOTE_ADDR" => env["REMOTE_ADDR"] } if client.config.send_default_pii && env["REMOTE_ADDR"]
        info
      end
    end
  end
end
