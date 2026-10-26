# frozen_string_literal: true

module NaijaCloud
  module Argus
    # OTLP/HTTP JSON builders (spec §5): only the fields Argus reads. JSON, not
    # protobuf, so the gem needs no protobuf dependency.
    module OTLP
      SEVERITY = { trace: 1, debug: 5, info: 9, warn: 13, error: 17, fatal: 21 }.freeze
      SCOPE = { name: "argus" }.freeze

      module_function

      def attrs(hash)
        return [] if hash.nil?

        hash.each_with_object([]) do |(key, v), out|
          next if v.nil?

          value = case v
                  when true, false then { boolValue: v }
                  when Integer then { intValue: v.to_s }
                  when Float then v.finite? ? { doubleValue: v } : { stringValue: v.to_s }
                  else { stringValue: v.to_s }
                  end
          out << { key: key.to_s, value: value }
        end
      end

      # Unix nanoseconds as a string: JSON numbers lose precision past 2**53.
      def nanos(time_s)
        (time_s * 1_000_000_000).round.to_s
      end

      def logs(resource, records)
        {
          resourceLogs: [{
            resource: { attributes: attrs(resource) },
            scopeLogs: [{
              scope: SCOPE,
              logRecords: records.map do |r|
                rec = {
                  timeUnixNano: nanos(r[:time]),
                  severityNumber: SEVERITY.fetch(r[:severity]),
                  severityText: r[:severity].to_s.upcase,
                  body: { stringValue: r[:body] },
                  attributes: attrs(r[:attributes]),
                }
                rec[:traceId] = r[:trace_id] if r[:trace_id]
                rec[:spanId] = r[:span_id] if r[:span_id]
                rec
              end,
            }],
          }],
        }
      end

      def traces(resource, spans)
        {
          resourceSpans: [{
            resource: { attributes: attrs(resource) },
            scopeSpans: [{
              scope: SCOPE,
              spans: spans.map do |s|
                span = { traceId: s[:trace_id], spanId: s[:span_id] }
                span[:parentSpanId] = s[:parent_span_id] if s[:parent_span_id]
                span.merge(
                  name: s[:name],
                  kind: s[:kind],
                  startTimeUnixNano: nanos(s[:start]),
                  endTimeUnixNano: nanos(s[:end]),
                  attributes: attrs(s[:attributes]),
                  status: s[:error] ? { code: 2, message: s[:error] } : { code: 1 },
                )
              end,
            }],
          }],
        }
      end

      def metrics(resource, points)
        metrics = points.map do |p|
          base = { name: p[:name] }
          base[:unit] = p[:unit] if p[:unit]
          attributes = attrs(p[:attributes])
          case p[:kind]
          when :sum
            base.merge(sum: {
              aggregationTemporality: 1, # delta (spec §5)
              isMonotonic: true,
              dataPoints: [{ attributes: attributes, startTimeUnixNano: nanos(p[:start]),
                             timeUnixNano: nanos(p[:end]), asDouble: p[:value].to_f }],
            })
          when :gauge
            base.merge(gauge: { dataPoints: [{ attributes: attributes, timeUnixNano: nanos(p[:end]), asDouble: p[:value].to_f }] })
          else
            base.merge(histogram: {
              aggregationTemporality: 1,
              dataPoints: [{
                attributes: attributes,
                startTimeUnixNano: nanos(p[:start]),
                timeUnixNano: nanos(p[:end]),
                count: p[:count].to_s,
                sum: p[:sum].to_f,
                min: p[:min].to_f,
                max: p[:max].to_f,
                explicitBounds: p[:bounds],
                bucketCounts: p[:buckets].map(&:to_s),
              }],
            })
          end
        end
        { resourceMetrics: [{ resource: { attributes: attrs(resource) }, scopeMetrics: [{ scope: SCOPE, metrics: metrics }] }] }
      end
    end
  end
end
