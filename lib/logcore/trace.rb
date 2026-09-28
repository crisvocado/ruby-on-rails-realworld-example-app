# frozen_string_literal: true

require "securerandom"

module Logcore
  module Trace
    TRACEPARENT_REGEX = /\A([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/i

    def self.from_traceparent(header)
      return nil if header.nil? || header.empty?
      clean = header.strip
      if clean =~ TRACEPARENT_REGEX
        trace_id = $2.downcase
        span_id = $3.downcase
        flags = $4.to_i(16)
        sampled = (flags & 1) == 1
        {
          traceId: trace_id,
          spanId: span_id,
          sampled: sampled
        }
      end
    end

    def self.from_env(env)
      raw = env["HTTP_TRACEPARENT"] || env["HTTP_X_TRACEPARENT"] || env["traceparent"]
      if raw
        parsed = from_traceparent(raw)
        return parsed if parsed
      end

      generate
    end

    def self.generate(sampled: true)
      {
        traceId: SecureRandom.hex(16),
        spanId: SecureRandom.hex(8),
        sampled: sampled
      }
    end

    def self.to_traceparent(trace)
      return nil unless trace.is_a?(Hash)
      trace_id = trace[:traceId] || trace["traceId"]
      span_id = trace[:spanId] || trace["spanId"]
      return nil unless trace_id && span_id
      sampled = trace.key?(:sampled) ? trace[:sampled] : trace["sampled"]
      flags = sampled ? "01" : "00"
      "00-#{trace_id}-#{span_id}-#{flags}"
    end
  end
end
