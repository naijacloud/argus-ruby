# frozen_string_literal: true

module NaijaCloud
  module Argus
    # Privacy defaults (spec §7). Ingest applies the same rules again on
    # arrival; the SDK does not rely on that, because a value that never leaves
    # the process cannot leak in transit or in a proxy's log.
    module Scrub
      FILTERED = "[Filtered]"

      CONTAINS = %w[
        password passwd secret token apikey accesskey authorization credential
        cookie privatekey cardnumber creditcard bvn cvv cvc sessionid
        sessiontoken signature
      ].freeze
      EXACT = %w[auth pwd pin otp session card sid].freeze

      CARD = /\b(?:\d[ -]?){12,18}\d\b/.freeze
      CREDENTIAL = %r{\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{8,}}i.freeze
      JWT = /\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\b/.freeze
      KV = /\b([a-z0-9_-]*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential|bvn|cvv)[a-z0-9_-]*)(\s*[:=]\s*)(["']?)([^"'\s,;&})]+)/i.freeze

      MAX_DEPTH = 8

      module_function

      # Whether a field's value should be filtered: lowercased with `-`, `_`
      # and spaces removed, it contains or equals one of the listed words.
      def sensitive_key?(key)
        n = key.to_s.downcase.delete("-_ ")
        EXACT.include?(n) || CONTAINS.any? { |c| n.include?(c) }
      end

      # Filters card numbers, credentials, JWTs and sensitive key=value pairs
      # inside a string.
      def scrub_string(str)
        return str if str.nil? || str.empty?

        str = str.dup.force_encoding(Encoding::UTF_8)
        str = str.scrub("?") unless str.valid_encoding?
        str
          .gsub(CARD) { |m| card?(m.delete(" -")) ? FILTERED : m }
          .gsub(CREDENTIAL) { "#{Regexp.last_match(1)} #{FILTERED}" }
          .gsub(JWT, FILTERED)
          .gsub(KV) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{Regexp.last_match(3)}#{FILTERED}" }
      end

      # Deep-scrubs a JSON-like value into a new one. Hash keys become strings.
      # Cycles and anything nested deeper than 8 are cut rather than followed,
      # so a self-referencing object cannot hang the request that reports it.
      def scrub(value, depth = 0, seen = {})
        case value
        when String then scrub_string(value)
        when Symbol then scrub_string(value.to_s)
        when nil, true, false, Integer then value
        when Float then value.finite? ? value : value.to_s
        when Hash, Array
          return "[…]" if depth > MAX_DEPTH || seen.key?(value.object_id)

          seen[value.object_id] = true
          out = if value.is_a?(Array)
                  value.map { |v| scrub(v, depth + 1, seen) }
                else
                  value.each_with_object({}) do |(k, v), acc|
                    acc[k.to_s] = sensitive_key?(k) && !blank?(v) ? FILTERED : scrub(v, depth + 1, seen)
                  end
                end
          seen.delete(value.object_id)
          out
        else
          scrub_string(safe_to_s(value))
        end
      end

      # Removes the query string and fragment from a URL (spec §7).
      def strip_query(url)
        url = url.to_s
        i = url.index(/[?#]/)
        i ? url[0, i] : url
      end

      def card?(digits)
        return false unless digits.length.between?(13, 19)

        sum = 0
        digits.reverse.each_char.with_index do |ch, i|
          d = ch.ord - 48
          if i.odd?
            d *= 2
            d -= 9 if d > 9
          end
          sum += d
        end
        (sum % 10).zero?
      end

      def blank?(value)
        value.nil? || value == ""
      end

      def safe_to_s(value)
        value.to_s
      rescue StandardError
        "#<#{value.class}>"
      end
    end
  end
end
