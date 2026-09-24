# frozen_string_literal: true

require "securerandom"

module Logcore
  class Middleware
    TRACEPARENT_REGEX = /\A00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/

    def initialize(app)
      @app = app
    end

    def call(env)
      trace_info = extract_or_generate_trace(env)
      request_context = {
        "http_method" => env["REQUEST_METHOD"],
        "path" => env["PATH_INFO"],
        "remote_addr" => env["REMOTE_ADDR"]
      }

      Logcore::Current.trace = trace_info
      Logcore::Current.context = request_context

      begin
        status, headers, body = @app.call(env)
        [status, headers, body]
      rescue Exception => ex
        Logcore.capture_exception(
          ex,
          severity: "FATAL",
          context: request_context,
          trace: trace_info
        )
        raise
      ensure
        Logcore::Current.reset
      end
    end

    private

    def extract_or_generate_trace(env)
      raw_header = env["HTTP_TRACEPARENT"] || env["HTTP_X_TRACEPARENT"] || env["traceparent"]

      if raw_header && raw_header =~ TRACEPARENT_REGEX
        trace_id = $1
        span_id = SecureRandom.hex(8)
        flags = $3.to_i(16)
        sampled = (flags & 1) == 1

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
