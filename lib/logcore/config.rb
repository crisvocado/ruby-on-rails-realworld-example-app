# frozen_string_literal: true

require "logger"

module Logcore
  class Config
    attr_accessor :endpoint, :api_key, :service, :env, :min_severity
    attr_writer :enabled

    VALID_ENVS = %w[prod staging dev test local].freeze

    def initialize
      @endpoint = ENV["LOGCORE_URL"] || "https://logcore-dev-352942961463.us-east4.run.app"
      @api_key = ENV["LOGCORE_KEY"]
      @enabled = parse_enabled(ENV["LOGCORE_ENABLED"])
      @service = sanitize_service(ENV["LOGCORE_SERVICE"] || default_service_name)
      @env = normalize_env(ENV["LOGCORE_ENV"] || default_env)
      @min_severity = parse_severity(ENV["LOGCORE_MIN_SEVERITY"])
    end

    def enabled?
      return @enabled unless @enabled.nil?

      # If explicitly set in config, respect it
      # Otherwise enable if api_key is present or in stub/test mode
      true
    end

    private

    def parse_enabled(val)
      return nil if val.nil? || val.empty?
      !%w[0 false no off].include?(val.to_s.downcase.strip)
    end

    def default_service_name
      if defined?(Rails) && Rails.application
        app_name = Rails.application.class.module_parent_name rescue nil
        app_name ||= Rails.application.class.to_s.deconstantize rescue nil
        return app_name.underscore.dasherize if app_name && !app_name.empty?
      end
      "ruby-on-rails-realworld-example-app"
    end

    def sanitize_service(name)
      cleaned = name.to_s.downcase.gsub(/[^a-z0-9._-]/, "-").gsub(/-+/, "-").gsub(/\A[^a-z0-9]+/, "")
      cleaned = "ruby-app" if cleaned.empty?
      cleaned[0...63]
    end

    def default_env
      defined?(Rails) ? Rails.env.to_s : "dev"
    end

    def normalize_env(raw)
      case raw.to_s.downcase.strip
      when "production", "prod" then "prod"
      when "staging", "stage" then "staging"
      when "development", "dev" then "dev"
      when "test", "testing" then "test"
      when "local" then "local"
      else
        VALID_ENVS.include?(raw) ? raw : "dev"
      end
    end

    def parse_severity(val)
      case val.to_s.upcase.strip
      when "DEBUG" then ::Logger::DEBUG
      when "INFO" then ::Logger::INFO
      when "WARN", "WARNING" then ::Logger::WARN
      when "FATAL" then ::Logger::FATAL
      when "UNKNOWN" then ::Logger::UNKNOWN
      else ::Logger::ERROR
      end
    end
  end
end
