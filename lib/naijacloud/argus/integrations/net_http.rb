# frozen_string_literal: true

require "net/http"

module NaijaCloud
  module Argus
    module Integrations
      # Outgoing Net::HTTP requests (and every client built on it: Faraday's
      # default adapter, HTTParty, RestClient, ActiveResource): a breadcrumb
      # each, and inside a span a child client span plus a W3C `traceparent`
      # header so the service called continues the trace (spec §5).
      module NetHTTP
        @installed = false

        def self.install
          return if @installed

          @installed = true
          ::Net::HTTP.prepend(Patch)
        end

        module Patch
          def request(req, body = nil, &block)
            # Net::HTTP#request calls itself again from inside `start` when
            # the connection was not open yet; trace the inner call only.
            return super unless started?
            return super if Transport.internal?

            client = Argus.client
            return super unless client&.enabled?

            Argus::Integrations::NetHTTP.traced(client, self, req) { super }
          end
        end

        def self.traced(client, http, req)
          method = req.method.to_s
          port = http.port == (http.use_ssl? ? 443 : 80) ? "" : ":#{http.port}"
          url = "#{http.use_ssl? ? 'https' : 'http'}://#{http.address}#{port}#{Scrub.strip_query(req.path)}"
          span = nil
          if Span.current
            span = client.start_span("#{method} #{url}", kind: Span::KIND_CLIENT,
                                                          attributes: { "http.request.method" => method, "url.full" => url,
                                                                        "server.address" => http.address })
            req["traceparent"] = span.traceparent if client.config.trace_propagation && req["traceparent"].nil?
          end

          begin
            res = yield
          rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised
            span&.finish(e)
            crumb(client, method, url, nil, "error")
            raise
          end

          code = res.code.to_i
          if span
            span.set_attribute("http.response.status_code", code)
            span.finish(code >= 500 ? "HTTP #{code}" : nil)
          end
          crumb(client, method, url, code, code >= 500 ? "error" : nil)
          res
        end

        def self.crumb(client, method, url, status, level)
          data = { method: method, url: url }
          data[:status_code] = status if status
          c = { type: "http", category: "net.http", data: data }
          c[:level] = level if level
          client.add_breadcrumb(c)
        rescue StandardError
          nil
        end
      end
    end
  end
end
