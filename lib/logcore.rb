# frozen_string_literal: true

require_relative "logcore/version"
require_relative "logcore/config"
require_relative "logcore/context"
require_relative "logcore/trace"
require_relative "logcore/stack_parser"
require_relative "logcore/entry"
require_relative "logcore/transport"
require_relative "logcore/logger_adapter"
require_relative "logcore/middleware"

module Logcore
  @config = nil
  @transport = nil
  @mutex = Mutex.new

  def self.config
    @config ||= Config.new
  end

  def self.configure
    yield(config)
  end

  def self.transport
    @transport ||= Transport.new(config)
  end

  def self.setup(app = nil)
    @mutex.synchronize do
      # Initialize config and transport
      _ = transport

      # Attach to Rails.logger
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        LoggerAdapter.attach(Rails.logger)
      end

      # Register middleware if app provides middleware config and not frozen
      if app && app.respond_to?(:config) && app.config.respond_to?(:middleware)
        begin
          app.config.middleware.use(Logcore::Middleware)
        rescue FrozenError
          # Middleware stack already built
        end
      end
    end
  end

  def self.flush(timeout: 5)
    @transport&.flush(timeout: timeout)
  end

  def self.close(timeout: 5)
    @transport&.close(timeout: timeout)
  end

  def self.stub_transport!(&block)
    transport.stub!(&block)
  end

  def self.unstub_transport!
    transport.unstub!
  end

  def self.reset!
    @mutex.synchronize do
      @transport&.close(timeout: 1)
      @transport = nil
      @config = nil
    end
  end
end
