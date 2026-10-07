# frozen_string_literal: true

module Logcore
  class Config
    DEFAULT_URL = "https://logcore-dev-352942961463.us-east4.run.app"
    DEFAULT_SERVICE = "realworld-rails"
    DEFAULT_MIN_SEVERITY = "ERROR"

    attr_accessor :url, :api_key, :service, :env, :min_severity, :enabled

    def initialize
      @url = ENV["LOGCORE_URL"] || DEFAULT_URL
      @api_key = ENV["LOGCORE_KEY"]
      @service = sanitize_service(ENV["LOGCORE_SERVICE"] || default_service_name)
      @env = normalize_env(ENV["LOGCORE_ENV"] || (defined?(Rails) && Rails.env ? Rails.env.to_s : "dev"))
      @min_severity = (ENV["LOGCORE_MIN_SEVERITY"] || DEFAULT_MIN_SEVERITY).to_s.upcase
      @enabled = parse_boolean(ENV["LOGCORE_ENABLED"], default: true)
    end

    def endpoint_path
      "/v1/logs"
    end

    def ingest_url
      "#{@url.to_s.sub(%r{/+\z}, '')}#{endpoint_path}"
    end

    private

    def sanitize_service(name)
      clean = name.to_s.downcase.gsub(/[^a-z0-9._-]/, "-").sub(/^[^a-z0-9]+/, "")
      clean = DEFAULT_SERVICE if clean.empty?
      clean[0...63]
    end

    def default_service_name
      if defined?(Rails) && Rails.application
        name = Rails.application.class.module_parent_name.to_s.underscore.dasherize
        name = sanitize_service(name)
        name.empty? ? DEFAULT_SERVICE : name
      else
        DEFAULT_SERVICE
      end
    end

    def normalize_env(e)
      case e.to_s.downcase
      when "production", "prod" then "prod"
      when "staging" then "staging"
      when "test" then "test"
      when "local" then "local"
      when "development", "dev" then "dev"
      else "dev"
      end
    end

    def parse_boolean(val, default:)
      return default if val.nil? || val.to_s.strip.empty?
      !%w[0 false no off].include?(val.to_s.strip.downcase)
    end
  end
end
