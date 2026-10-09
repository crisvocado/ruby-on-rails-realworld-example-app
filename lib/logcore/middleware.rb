# frozen_string_literal: true

module Logcore
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      traceparent = env["HTTP_TRACEPARENT"]
      if traceparent
        parsed_trace = Formatter.parse_traceparent(traceparent)
        Current.trace = parsed_trace if parsed_trace
      end

      request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
      path = env["PATH_INFO"]
      method = env["REQUEST_METHOD"]

      ctx = {}
      ctx["request_id"] = request_id if request_id.present?
      ctx["path"] = path if path.present?
      ctx["method"] = method if method.present?

      Current.context = ctx unless ctx.empty?

      @app.call(env)
    rescue Exception => e
      # Ensure unhandled exception is forwarded to Rails logger
      Rails.logger.error(e) if defined?(Rails.logger) && Rails.logger
      raise e
    ensure
      Current.reset if defined?(Current) && Current.respond_to?(:reset)
    end
  end
end
