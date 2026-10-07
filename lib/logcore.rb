# frozen_string_literal: true

require_relative "logcore/config"
require_relative "logcore/formatter"
require_relative "logcore/client"
require_relative "logcore/logger_adapter"
require_relative "logcore/middleware"

module Logcore
  class << self
    def config
      @config ||= Config.new
    end

    def configure
      yield(config) if block_given?
    end

    def client
      @client ||= Client.new(config)
    end

    def logger_adapter
      @logger_adapter ||= LoggerAdapter.new(config, client)
    end

    def flush(timeout: 5.0)
      client.flush(timeout: timeout)
    end

    def stub_transport!(&block)
      client.stub_transport!(&block)
    end

    def restore_transport!
      client.restore_transport!
    end

    def ingest_url
      client.ingest_url
    end

    def attach_to_rails_logger!
      return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      if defined?(ActiveSupport::Logger) && ActiveSupport::Logger.respond_to?(:broadcast)
        Rails.logger.extend(ActiveSupport::Logger.broadcast(logger_adapter))
      elsif Rails.logger.respond_to?(:broadcast_to)
        Rails.logger.broadcast_to(logger_adapter)
      end
    end
  end
end
