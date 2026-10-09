# frozen_string_literal: true

require "uri"

module Logcore
  class Configuration
    DEFAULT_ENDPOINT = "https://logcore-dev-352942961463.us-east4.run.app"
    VALID_ENVS = %w[prod staging dev test local].freeze
    SEVERITY_LEVELS = {
      "DEBUG" => 0,
      "INFO" => 1,
      "WARN" => 2,
      "WARNING" => 2,
      "ERROR" => 3,
      "CRITICAL" => 4,
      "FATAL" => 4,
      "ALERT" => 4,
      "EMERGENCY" => 4,
      "UNKNOWN" => 3
    }.freeze

    attr_accessor :url, :key, :enabled, :service, :env, :min_severity

    def initialize
      @url = ENV["LOGCORE_URL"].presence || DEFAULT_ENDPOINT
      @key = ENV["LOGCORE_KEY"]
      @enabled = if ENV.key?("LOGCORE_ENABLED")
                   ENV["LOGCORE_ENABLED"].to_s.strip.downcase == "true"
                 else
                   !@key.nil? && !@key.strip.empty?
                 end
      @service = sanitize_service(ENV["LOGCORE_SERVICE"].presence || default_service_name)
      @env = normalize_env(ENV["LOGCORE_ENV"].presence || (defined?(Rails) ? Rails.env.to_s : "dev"))
      @min_severity = (ENV["LOGCORE_MIN_SEVERITY"].presence || "ERROR").upcase
    end

    def min_severity_level
      SEVERITY_LEVELS[@min_severity] || 3
    end

    private

    def default_service_name
      if defined?(Rails) && Rails.application
        app_name = Rails.application.class.module_parent_name rescue nil
        app_name ||= Rails.application.class.name.split("::").first rescue nil
        app_name ? app_name.to_s.underscore.dasherize : "realworld"
      else
        "realworld"
      end
    end

    def sanitize_service(name)
      sanitized = name.to_s.downcase.gsub(/[^a-z0-9._-]/, "-").gsub(/-+/, "-")
      sanitized = sanitized[0...63]
      sanitized = "service" if sanitized.empty? || !sanitized.match?(/^[a-z0-9]/)
      sanitized
    end

    def normalize_env(env_str)
      val = env_str.to_s.downcase.strip
      case val
      when "production", "prod"
        "prod"
      when "staging"
        "staging"
      when "development", "dev"
        "dev"
      when "test"
        "test"
      when "local"
        "local"
      else
        VALID_ENVS.include?(val) ? val : "dev"
      end
    end
  end
end
