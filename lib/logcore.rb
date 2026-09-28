# frozen_string_literal: true

require "logger"
require_relative "logcore/version"
require_relative "logcore/config"
require_relative "logcore/entry"
require_relative "logcore/transport"
require_relative "logcore/logger_adapter"
require_relative "logcore/middleware"

module Logcore
  THREAD_TRACE_KEY = :_logcore_trace
  THREAD_LABELS_KEY = :_logcore_labels
  THREAD_CONTEXT_KEY = :_logcore_context

  class << self
    attr_reader :config, :transport, :adapter

    def setup(app = (defined?(Rails.application) ? Rails.application : nil), overrides = {})
      return if @installed && overrides.empty?

      @config = Logcore::Config.new(overrides)
      @transport = Logcore::Transport.new(@config)
      @adapter = Logcore::LoggerAdapter.new(@transport, @config)

      attach_to_logger
      attach_middleware(app) if app

      @installed = true
      self
    end

    def installed?
      !!@installed
    end

    def flush(timeout: 5.0)
      @transport&.flush(timeout: timeout)
    end

    def flush_and_stop(timeout: 5.0)
      @transport&.flush_and_stop(timeout: timeout)
    end

    # Context and Trace thread-local accessors
    def current_trace
      Thread.current[THREAD_TRACE_KEY]
    end

    def current_trace=(trace)
      Thread.current[THREAD_TRACE_KEY] = trace
    end

    def current_labels
      Thread.current[THREAD_LABELS_KEY]
    end

    def current_labels=(labels)
      Thread.current[THREAD_LABELS_KEY] = labels
    end

    def current_context
      Thread.current[THREAD_CONTEXT_KEY]
    end

    def current_context=(context)
      Thread.current[THREAD_CONTEXT_KEY] = context
    end

    def with_context(trace: nil, labels: nil, context: nil)
      prev_trace = current_trace
      prev_labels = current_labels
      prev_context = current_context

      self.current_trace = trace if trace
      self.current_labels = labels if labels
      self.current_context = context if context

      yield
    ensure
      self.current_trace = prev_trace
      self.current_labels = prev_labels
      self.current_context = prev_context
    end

    private

    def attach_to_logger
      return unless defined?(Rails.logger) && Rails.logger
      return if @logger_attached

      if defined?(ActiveSupport::Logger) && ActiveSupport::Logger.respond_to?(:broadcast)
        Rails.logger.extend(ActiveSupport::Logger.broadcast(@adapter))
      elsif Rails.logger.respond_to?(:extend)
        adapter = @adapter
        broadcast_mod = Module.new do
          define_method(:add) do |*args, &block|
            adapter.add(*args, &block) rescue nil
            super(*args, &block)
          end
        end
        Rails.logger.extend(broadcast_mod)
      end

      @logger_attached = true
    end

    def attach_middleware(app)
      return unless app.respond_to?(:middleware)
      return if @middleware_attached

      # Insert middleware to capture request trace and uncaught errors
      if app.middleware.respond_to?(:use)
        app.middleware.use Logcore::Middleware
        @middleware_attached = true
      end
    end
  end
end
