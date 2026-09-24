# frozen_string_literal: true

module Logcore
  class ErrorSubscriber
    def report(error, handled: nil, severity: :error, context: {}, source: nil)
      sev_str = severity.to_s.upcase == "FATAL" ? "FATAL" : "ERROR"
      ctx = context.is_a?(Hash) ? context.dup : {}
      ctx["handled"] = handled unless handled.nil?
      ctx["source"] = source.to_s if source

      Logcore.capture_exception(
        error,
        severity: sev_str,
        context: ctx
      )
    rescue => e
      # Never crash error reporting
    end
  end
end
