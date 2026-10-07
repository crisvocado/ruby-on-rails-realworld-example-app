# frozen_string_literal: true

module Logcore
  class Middleware
    TRACEPARENT_REGEX = /\A([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/.freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      trace_context = parse_traceparent(env["HTTP_TRACEPARENT"])
      Thread.current[:logcore_trace_context] = trace_context

      begin
        @app.call(env)
      ensure
        Thread.current[:logcore_trace_context] = nil
      end
    end

    private

    def parse_traceparent(header)
      return nil unless header.is_a?(String)

      header = header.strip
      match = TRACEPARENT_REGEX.match(header)
      return nil unless match

      version, trace_id, span_id, flags = match.captures
      return nil if trace_id == "00000000000000000000000000000000"
      return nil if span_id == "0000000000000000"

      sampled = (flags.to_i(16) & 1) == 1

      {
        traceId: trace_id,
        spanId: span_id,
        sampled: sampled
      }
    end
  end
end
