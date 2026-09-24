# frozen_string_literal: true

require "uri"

module Logcore
  class Configuration
    attr_accessor :url,
                  :api_key,
                  :enabled,
                  :service,
                  :env,
                  :min_severity,
                  :buffer_capacity,
                  :batch_size,
                  :max_batch_size,
                  :flush_interval_seconds,
                  :max_retries,
                  :circuit_breaker_threshold

    def initialize
      @url = ENV.fetch("LOGCORE_URL", "https://logcore-dev-352942961463.us-east4.run.app")
      @api_key = ENV["LOGCORE_KEY"]
      @enabled = determine_enabled
      @service = determine_service
      @env = determine_env
      @min_severity = ENV.fetch("LOGCORE_MIN_SEVERITY", "ERROR").upcase
      @buffer_capacity = 1000
      @batch_size = 20
      @max_batch_size = 200
      @flush_interval_seconds = 5.0
      @max_retries = 3
      @circuit_breaker_threshold = 10
    end

    def enabled?
      !!@enabled
    end

    def ingest_uri
      @ingest_uri ||= URI.parse("#{url.to_s.chomp('/')}/v1/logs")
    end

    private

    def determine_enabled
      val = ENV["LOGCORE_ENABLED"]
      return false if val == "false" || val == "0"
      return true if val == "true" || val == "1"

      true
    end

    def determine_service
      raw = ENV["LOGCORE_SERVICE"]
      if raw.nil? || raw.strip.empty?
        if defined?(Rails.application) && Rails.application
          raw = Rails.application.class.module_parent_name.to_s.underscore.dasherize
        end
      end
      raw = "realworld-rails" if raw.nil? || raw.strip.empty?
      # Ensure service matches ^[a-z0-9][a-z0-9._-]{0,62}$
      sanitized = raw.downcase.gsub(/[^a-z0-9._-]/, "-").gsub(/\A[^a-z0-9]+/, "")
      sanitized = "realworld-rails" if sanitized.empty?
      sanitized[0...63]
    end

    def determine_env
      raw = ENV["LOGCORE_ENV"]
      if raw.nil? || raw.strip.empty?
        if defined?(Rails.env) && Rails.env
          case Rails.env.to_s
          when "production" then "prod"
          when "staging" then "staging"
          when "development" then "dev"
          when "test" then "test"
          else "dev"
          end
        else
          "dev"
        end
      else
        case raw.downcase
        when "production", "prod" then "prod"
        when "staging" then "staging"
        when "development", "dev" then "dev"
        when "test" then "test"
        when "local" then "local"
        else "dev"
        end
      end
    end
  end
end
