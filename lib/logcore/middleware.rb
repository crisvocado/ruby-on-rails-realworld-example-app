# frozen_string_literal: true

module Logcore
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      trace = Trace.from_env(env)
      Context.with_trace(trace) do
        status, headers, response = @app.call(env)
        
        # Inject traceparent into response headers if headers is a Hash
        if headers.is_a?(Hash) && trace
          tp = Trace.to_traceparent(trace)
          headers["traceparent"] = tp if tp
        end

        [status, headers, response]
      end
    rescue Exception => e
      # Log unhandled exception through Rails.logger
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.error(e)
      end
      raise
    end
  end
end
