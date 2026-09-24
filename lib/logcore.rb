# frozen_string_literal: true

require_relative "logcore/version"
require_relative "logcore/configuration"
require_relative "logcore/stack_trace"
require_relative "logcore/entry"
require_relative "logcore/transport"
require_relative "logcore/current"
require_relative "logcore/middleware"
require_relative "logcore/http_patch"
require_relative "logcore/logger_adapter"
require_relative "logcore/error_subscriber"

module Logcore
  class << self
    attr_writer :configuration, :transport, :adapter

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
    end

    def transport
      @transport ||= Transport.new(configuration)
    end

    def adapter
      @adapter ||= LoggerAdapter.new
    end

    def setup
      return if @setup_complete

      # Broadcast logger adapter to Rails.logger
      if defined?(Rails.logger) && Rails.logger
        if defined?(ActiveSupport::Logger) && ActiveSupport::Logger.respond_to?(:broadcast)
          Rails.logger.extend(ActiveSupport::Logger.broadcast(adapter))
        end
      end

      # Subscribe to Rails.error (Rails 7+)
      if defined?(Rails.error) && Rails.error.respond_to?(:subscribe)
        Rails.error.subscribe(ErrorSubscriber.new)
      end

      # Install outgoing HTTP traceparent forwarding
      HttpPatch.install!

      # Flush on clean exit
      at_exit do
        Logcore.flush(timeout: 3.0)
        Logcore.shutdown(timeout: 2.0)
      end

      @setup_complete = true
    end

    def capture(message:, severity: "ERROR", exception: nil, context: nil, labels: nil, trace: nil)
      return unless configuration.enabled?

      error_data = StackTrace.extract_error(exception, message)
      merged_trace = trace || Current.trace
      current_ctx = Current.context.is_a?(Hash) ? Current.context : {}
      passed_ctx = context.is_a?(Hash) ? context : {}
      merged_context = current_ctx.merge(passed_ctx)

      current_lbl = Current.labels.is_a?(Hash) ? Current.labels : {}
      passed_lbl = labels.is_a?(Hash) ? labels : {}
      merged_labels = current_lbl.merge(passed_lbl)

      entry = Entry.new(
        message: message,
        severity: severity,
        trace: merged_trace,
        error: error_data,
        labels: merged_labels.empty? ? nil : merged_labels,
        context: merged_context.empty? ? nil : merged_context
      )

      transport.enqueue(entry)
      entry
    rescue => e
      # Logging must never crash the host application
      nil
    end

    def capture_exception(exception, severity: "ERROR", context: nil, labels: nil, trace: nil)
      msg = exception.respond_to?(:message) ? exception.message : exception.to_s
      capture(
        message: msg,
        severity: severity,
        exception: exception,
        context: context,
        labels: labels,
        trace: trace
      )
    end

    def flush(timeout: 5.0)
      transport.flush(timeout: timeout)
    end

    def shutdown(timeout: 5.0)
      transport.shutdown(timeout: timeout)
    end
  end
end
