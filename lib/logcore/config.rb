# frozen_string_literal: true

require "logger"

module Logcore
  class Config
    DEFAULT_ENDPOINT = "https://logcore-dev-352942961463.us-east4.run.app"
    DEFAULT_SERVICE = "realworld"
    VALID_ENVS = %w[prod staging dev test local].freeze

    SEVERITY_LEVELS = {
      "DEBUG" => ::Logger::DEBUG,
      "INFO" => ::Logger::INFO,
      "WARN" => ::Logger::WARN,
      "ERROR" => ::Logger::ERROR,
      "FATAL" => ::Logger::FATAL,
      "UNKNOWN" => ::Logger::UNKNOWN
    }.freeze

    attr_accessor :url, :key, :enabled, :service, :env, :min_severity,
                  :buffer_cap, :batch_size, :flush_interval,
                  :max_batch_size, :max_retries, :circuit_breaker_threshold

    def initialize(overrides = {})
      @url = overrides[:url] || ENV["LOGCORE_URL"] || DEFAULT_ENDPOINT
      @key = overrides[:key] || ENV["LOGCORE_KEY"]
      
      raw_enabled = overrides.key?(:enabled) ? overrides[:enabled] : ENV["LOGCORE_ENABLED"]
      @enabled = if raw_enabled.nil?
                   true
                 elsif raw_enabled.is_a?(String)
                   raw_enabled != "false" && raw_enabled != "0"
                 else
                   !!raw_enabled
                 end

      @service = normalize_service(overrides[:service] || ENV["LOGCORE_SERVICE"])
      @env = normalize_env(overrides[:env] || ENV["LOGCORE_ENV"])
      @min_severity = (overrides[:min_severity] || ENV["LOGCORE_MIN_SEVERITY"] || "ERROR").to_s.upcase

      @buffer_cap = (overrides[:buffer_cap] || 1000).to_i
      @batch_size = (overrides[:batch_size] || 20).to_i
      @flush_interval = (overrides[:flush_interval] || 5.0).to_f
      @max_batch_size = (overrides[:max_batch_size] || 200).to_i
      @max_retries = (overrides[:max_retries] || 3).to_i
      @circuit_breaker_threshold = (overrides[:circuit_breaker_threshold] || 10).to_i
    end

    def enabled?
      @enabled
    end

    def min_severity_level
      SEVERITY_LEVELS[@min_severity] || ::Logger::ERROR
    end

    private

    def normalize_service(raw_service)
      candidate = raw_service.to_s.strip
      if candidate.empty?
        if defined?(Rails.application) && Rails.application
          app_name = Rails.application.class.module_parent_name rescue nil
          candidate = app_name.to_s.underscore.tr("_", "-") if app_name
        end
        candidate = DEFAULT_SERVICE if candidate.empty?
      end

      # Enforce pattern ^[a-z0-9][a-z0-9._-]{0,62}$
      sanitized = candidate.downcase.gsub(/[^a-z0-9._-]/, "-").gsub(/\A[^a-z0-9]+/, "")
      sanitized = DEFAULT_SERVICE if sanitized.empty?
      sanitized[0...63]
    end

    def normalize_env(raw_env)
      candidate = raw_env.to_s.strip.downcase
      if candidate.empty?
        if defined?(Rails.env) && Rails.env
          candidate = Rails.env.to_s.downcase
        elsif ENV["RAILS_ENV"]
          candidate = ENV["RAILS_ENV"].to_s.downcase
        end
      end

      case candidate
      when "production", "prod"
        "prod"
      when "staging"
        "staging"
      when "test"
        "test"
      when "development", "dev"
        "dev"
      when "local"
        "local"
      else
        VALID_ENVS.include?(candidate) ? candidate : "dev"
      end
    end
  end
end
