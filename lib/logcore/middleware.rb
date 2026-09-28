# frozen_string_literal: true

require "securerandom"

module Logcore
  class Middleware
    TRACEPARENT_REGEX = /\A00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/i.freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      raw_traceparent = env["HTTP_TRACEPARENT"] || env["traceparent"]
      trace = parse_or_generate_trace(raw_traceparent)

      req_context = {
        "http" => {
          "method" => env["REQUEST_METHOD"].to_s,
          "path" => env["PATH_INFO"].to_s
        }
      }

      Logcore.with_context(trace: trace, context: req_context) do
        @app.call(env)
      end
    rescue Exception => e
      # Log unhandled exception with current trace context
      if defined?(Rails.logger) && Rails.logger
        Rails.logger.error(e) rescue nil
      end
      raise e
    end

    private

    def parse_or_generate_trace(raw_header)
      if raw_header && raw_header.to_s.strip =~ TRACEPARENT_REGEX
        trace_id = Regexp.last_match(1).downcase
        span_id = Regexp.last_match(2).downcase
        flags = Regexp.last_match(3).to_i(16)
        sampled = (flags & 1) != 0

        {
          "traceId" => trace_id,
          "spanId" => span_id,
          "sampled" => sampled
        }
      else
        {
          "traceId" => SecureRandom.hex(16),
          "spanId" => SecureRandom.hex(8),
          "sampled" => true
        }
      end
    end
  end
end
