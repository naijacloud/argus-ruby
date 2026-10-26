# frozen_string_literal: true

require "logger"

module NaijaCloud
  module Argus
    # A ::Logger that sends each line to Argus Logs instead of writing it
    # anywhere. Use it as a broadcast target next to your existing logger:
    #
    #   Rails.logger.broadcast_to(NaijaCloud::Argus::Logger.new(level: :info))   # Rails 7.1+
    #   logger = NaijaCloud::Argus::Logger.new                                     # plain Ruby
    #
    # or set `rails_logs = true` and the Railtie attaches one for you. A line
    # written inside a request carries that request's trace id.
    class Logger < ::Logger
      SEVERITIES = {
        ::Logger::DEBUG => :debug, ::Logger::INFO => :info, ::Logger::WARN => :warn,
        ::Logger::ERROR => :error, ::Logger::FATAL => :fatal, ::Logger::UNKNOWN => :fatal
      }.freeze
      ANSI = /\e\[[0-9;]*m/.freeze

      def initialize(level: ::Logger::DEBUG, progname: nil)
        super(nil, level: level, progname: progname)
      end

      def add(severity, message = nil, progname = nil)
        severity ||= ::Logger::UNKNOWN
        return true if severity < level || Transport.internal?

        if message.nil?
          if block_given?
            message = yield
          else
            message = progname
            progname = @progname
          end
        end
        text = case message
               when ::String then message
               when ::Exception then "#{message.class}: #{message.message}"
               else message.inspect
               end
        text = text.gsub(ANSI, "").strip
        return true if text.empty?

        attrs = progname ? { "logger.name" => progname.to_s } : nil
        Argus.safely { Argus.client&.log(SEVERITIES.fetch(severity, :info), text, attrs) }
        true
      end
      alias log add

      # Nothing to write to, so nothing to reopen or close.
      def reopen(_logdev = nil)
        self
      end

      def close; end
    end
  end
end
