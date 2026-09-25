# frozen_string_literal: true

require "logger"

module Logcore
  class Configuration
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

    attr_accessor :url, :key, :enabled, :service, :env, :min_severity

    def initialize
      @url = ENV["LOGCORE_URL"] || DEFAULT_ENDPOINT
      @key = ENV["LOGCORE_KEY"]
      @enabled = ENV["LOGCORE_ENABLED"] != "false"
      @service = ENV["LOGCORE_SERVICE"] || default_service_name
      @env = ENV["LOGCORE_ENV"] || default_environment
      @min_severity = ENV["LOGCORE_MIN_SEVERITY"] || "ERROR"
    end

    def enabled?
      @enabled && (!@key.to_s.strip.empty? || test_mode?)
    end

    def test_mode?
      defined?(Rails) && (Rails.env.test? || Rails.env.development?)
    end

    def min_severity_int
      SEVERITY_LEVELS[@min_severity.to_s.upcase] || ::Logger::ERROR
    end

    def normalized_service
      str = @service.to_s.strip.downcase
      cleaned = str.gsub(/[^a-z0-9._-]/, "-").sub(/^[^a-z0-9]+/, "")
      cleaned = "app" if cleaned.empty?
      cleaned[0, 63]
    end

    def normalized_env
      str = @env.to_s.strip.downcase
      case str
      when "production", "prod"
        "prod"
      when "staging", "stage"
        "staging"
      when "development", "dev"
        "dev"
      when "test"
        "test"
      when "local"
        "local"
      else
        VALID_ENVS.include?(str) ? str : "dev"
      end
    end

    private

    def default_service_name
      if defined?(Rails) && Rails.application
        Rails.application.class.module_parent_name&.downcase || DEFAULT_SERVICE
      else
        DEFAULT_SERVICE
      end
    end

    def default_environment
      if defined?(Rails) && Rails.env
        Rails.env.to_s
      else
        "dev"
      end
    end
  end
end
