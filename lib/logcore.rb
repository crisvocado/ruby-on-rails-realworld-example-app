# frozen_string_literal: true

require_relative "logcore/version"
require_relative "logcore/configuration"
require_relative "logcore/entry"
require_relative "logcore/client"
require_relative "logcore/buffer"
require_relative "logcore/logger_adapter"
require_relative "logcore/middleware"

module Logcore
  class << self
    attr_writer :configuration, :client, :buffer

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
    end

    def client
      @client ||= Client.new(configuration)
    end

    def buffer
      @buffer ||= Buffer.new(client)
    end

    def log(severity, message, progname = nil)
      return unless configuration.enabled?

      sev_int = severity_to_int(severity)
      return if sev_int < configuration.min_severity_int

      exception = nil
      if message.is_a?(Exception)
        exception = message
        message = exception.message
      elsif progname.is_a?(Exception)
        exception = progname
      end

      entry = Entry.build(
        severity: severity,
        message: message,
        exception: exception,
        trace: Thread.current[:logcore_trace],
        context: Thread.current[:logcore_context],
        configuration: configuration
      )

      buffer.push(entry)
    end

    def severity_to_int(sev)
      case sev
      when Integer
        sev
      when String, Symbol
        Configuration::SEVERITY_LEVELS[sev.to_s.upcase] || ::Logger::UNKNOWN
      else
        ::Logger::UNKNOWN
      end
    end

    def flush
      buffer.flush
    end

    def shutdown
      buffer.shutdown
    end

    def stub_transport(&block)
      old_stub = Client.stub_sender
      Client.stub_sender = block
      yield
    ensure
      Client.stub_sender = old_stub
    end

    def install(app = nil)
      return if @installed

      @installed = true

      # Mount Rack middleware for traceparent parsing
      if app && app.respond_to?(:config) && app.config.respond_to?(:middleware)
        app.config.middleware.use(Logcore::Middleware)
      elsif defined?(Rails) && Rails.application && Rails.application.config.respond_to?(:middleware)
        Rails.application.config.middleware.use(Logcore::Middleware)
      end

      # Broadcast to Logcore from Rails.logger
      if defined?(Rails) && Rails.logger && defined?(ActiveSupport::Logger)
        logger_adapter = Logcore::LoggerAdapter.new
        Rails.logger.extend(ActiveSupport::Logger.broadcast(logger_adapter))
      end

      # Flush pending logs on shutdown
      at_exit { Logcore.shutdown }
    end
  end
end
