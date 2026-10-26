# frozen_string_literal: true

require "uri"

module NaijaCloud
  module Argus
    # A parsed DSN: `https://<public_key>@<host>/<project_id>` (spec §1).
    class Dsn
      attr_reader :public_key, :project_id, :origin, :raw

      # Returns a Dsn, or nil for anything that is not one. Never raises: a
      # typo in an environment variable must not take the app down at boot.
      def self.parse(raw)
        return nil unless raw.is_a?(String)

        raw = raw.strip
        return nil if raw.empty?

        uri = URI.parse(raw)
        return nil unless %w[http https].include?(uri.scheme)
        return nil if uri.host.nil? || uri.host.empty?

        key = uri.user && URI.decode_www_form_component(uri.user)
        parts = uri.path.to_s.split("/").reject(&:empty?)
        project = parts.pop
        return nil if key.nil? || key.empty? || project.nil? || project !~ /\A\d+\z/

        prefix = parts.empty? ? "" : "/#{parts.join('/')}"
        port = uri.port == uri.default_port ? "" : ":#{uri.port}"
        new(public_key: key, project_id: project, origin: "#{uri.scheme}://#{uri.host}#{port}#{prefix}", raw: raw)
      rescue URI::Error, ArgumentError
        nil
      end

      def initialize(public_key:, project_id:, origin:, raw:)
        @public_key = public_key
        @project_id = project_id
        @origin = origin
        @raw = raw
      end

      # The error endpoint (spec §3). Servers authenticate with a header, so
      # the key stays out of the URL and out of any proxy's access log.
      def envelope_url
        "#{origin}/api/#{project_id}/envelope/"
      end

      def ingest_url(path)
        "#{origin}#{path}"
      end

      # The key is public by design, but a DSN dumped by an error reporter is
      # still noise nobody needs; show which source it is, not the key.
      def inspect
        "#<NaijaCloud::Argus::Dsn #{origin}/#{project_id}>"
      end
      alias to_s inspect
    end
  end
end
