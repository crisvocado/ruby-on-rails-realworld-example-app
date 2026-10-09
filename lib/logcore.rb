# frozen_string_literal: true

require_relative "logcore/configuration"
require_relative "logcore/current"
require_relative "logcore/formatter"
require_relative "logcore/transport"
require_relative "logcore/logger_adapter"
require_relative "logcore/middleware"
require_relative "logcore/railtie" if defined?(Rails::Railtie)

module Logcore
  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
    end

    def adapter
      @adapter ||= LoggerAdapter.new
    end

    def attach_logger(logger)
      return unless logger
      return if @attached

      if logger.respond_to?(:extend) && defined?(ActiveSupport::Logger.broadcast)
        logger.extend(ActiveSupport::Logger.broadcast(adapter))
        @attached = true
      end
    end

    def reset!
      @attached = false
      @adapter = nil
      @configuration = nil
      Transport.reset!
    end
  end
end

at_exit do
  Logcore::Transport.flush rescue nil
  Logcore::Transport.stop rescue nil
end
