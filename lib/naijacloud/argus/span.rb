# frozen_string_literal: true

require "securerandom"

module NaijaCloud
  module Argus
    # A unit of work in a trace. Finish it once.
    class Span
      KIND_INTERNAL = 1
      KIND_SERVER = 2
      KIND_CLIENT = 3

      TRACEPARENT = /\A00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/.freeze

      attr_reader :trace_id, :span_id, :parent_span_id, :kind, :start_time, :attributes
      attr_accessor :name

      # Parses a W3C traceparent header into `{trace_id:, span_id:, sampled:}`.
      def self.parse_traceparent(header)
        m = header && TRACEPARENT.match(header.to_s.strip)
        return nil if m.nil? || m[1] =~ /\A0+\z/ || m[2] =~ /\A0+\z/

        { trace_id: m[1], span_id: m[2], sampled: (m[3].to_i(16) & 1) == 1 }
      end

      # The span in progress on this thread (or fiber), if any.
      def self.current
        Thread.current[:naijacloud_argus_span]
      end

      # Runs the block with span as the current one.
      def self.with(span)
        prev = Thread.current[:naijacloud_argus_span]
        Thread.current[:naijacloud_argus_span] = span
        yield
      ensure
        Thread.current[:naijacloud_argus_span] = prev
      end

      def initialize(client, name, kind: KIND_INTERNAL, parent: nil, attributes: nil)
        @client = client
        @name = name.to_s
        @kind = kind
        @attributes = attributes ? attributes.dup : {}
        @trace_id = parent ? parent[:trace_id] : SecureRandom.hex(16)
        @parent_span_id = parent && parent[:span_id]
        @span_id = SecureRandom.hex(8)
        @sampled = parent ? parent[:sampled] : (client ? client.sample_trace? : false)
        @start_time = Time.now.to_f
        @finished = false
      end

      def sampled?
        @sampled
      end

      # Whether finishing this span sends anything.
      def recording?
        @sampled && !@client.nil?
      end

      def set_attribute(key, value)
        @attributes[key.to_s] = value
        self
      end

      def set_attributes(hash)
        hash.each { |k, v| set_attribute(k, v) }
        self
      end

      # The W3C traceparent for an outgoing request, so the service it calls
      # continues this trace.
      def traceparent
        "00-#{@trace_id}-#{@span_id}-#{@sampled ? '01' : '00'}"
      end

      # Ends the span. Pass the error (or a message) when the work failed.
      def finish(error = nil)
        return self if @finished

        @finished = true
        return self unless recording?

        message = case error
                  when nil, false then nil
                  when Exception then "#{error.class}: #{error.message}"
                  else error.to_s
                  end
        @client.record_span(
          trace_id: @trace_id, span_id: @span_id, parent_span_id: @parent_span_id,
          name: @name, kind: @kind, start: @start_time, end: Time.now.to_f,
          error: message, attributes: @attributes,
        )
        self
      rescue StandardError
        self
      end

      def finished?
        @finished
      end

      def inspect
        "#<NaijaCloud::Argus::Span #{@name.inspect} trace=#{@trace_id} span=#{@span_id}>"
      end
    end
  end
end
