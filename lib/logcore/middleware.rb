# frozen_string_literal: true

module Logcore
  class Middleware
    TRACEPARENT_REGEX = /\A00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/

    def initialize(app)
      @app = app
    end

    def call(env)
      trace = parse_traceparent(env["HTTP_TRACEPARENT"])
      request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]

      context = {}
      context["request_id"] = request_id if request_id
      context["http_method"] = env["REQUEST_METHOD"] if env["REQUEST_METHOD"]
      context["path"] = env["PATH_INFO"] if env["PATH_INFO"]

      Thread.current[:logcore_trace] = trace
      Thread.current[:logcore_context] = context.empty? ? nil : context

      @app.call(env)
    ensure
      Thread.current[:logcore_trace] = nil
      Thread.current[:logcore_context] = nil
    end

    private

    def parse_traceparent(header)
      return nil unless header.is_a?(String)

      if header.strip =~ TRACEPARENT_REGEX
        {
          "traceId" => $1,
          "spanId" => $2,
          "sampled" => ($3.to_i(16) & 1) == 1
        }
      end
    end
  end
end
