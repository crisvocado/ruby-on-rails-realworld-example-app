# frozen_string_literal: true

require "logger"

module Logcore
  class LoggerAdapter < ::Logger
    SEVERITY_NAMES = {
      ::Logger::DEBUG => "DEBUG",
      ::Logger::INFO => "INFO",
      ::Logger::WARN => "WARNING",
      ::Logger::ERROR => "ERROR",
      ::Logger::FATAL => "CRITICAL",
      ::Logger::UNKNOWN => "ERROR"
    }.freeze

    def initialize
      super(nil)
      self.level = ::Logger::ERROR
    end

    def add(severity, message = nil, progname = nil, &block)
      severity ||= ::Logger::UNKNOWN
      min_level = Logcore.configuration.min_severity_level

      return true if severity < min_level

      # Standard Ruby Logger argument resolution
      if message.nil?
        if block_given?
          message = yield
        else
          message = progname
          progname = nil
        end
      end

      exception = nil
      if message.is_a?(Exception)
        exception = message
        message = exception.message
      elsif $!.is_a?(Exception)
        exception = $!
      end

      severity_str = SEVERITY_NAMES[severity] || "ERROR"
      entry = Formatter.format_entry(severity_str, message, exception)
      Transport.enqueue(entry)

      true
    rescue => e
      $stderr.puts "[Logcore] LoggerAdapter error: #{e.message}"
      true
    end
  end
end
