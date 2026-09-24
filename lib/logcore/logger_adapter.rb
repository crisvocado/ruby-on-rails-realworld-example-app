# frozen_string_literal: true

require "logger"

module Logcore
  class LoggerAdapter < ::Logger
    def initialize
      super(nil)
      self.level = ::Logger::ERROR
    end

    def add(severity, message = nil, progname = nil, &block)
      severity_int = case severity
                     when Integer then severity
                     when :error, "ERROR", "error" then ::Logger::ERROR
                     when :fatal, "FATAL", "fatal" then ::Logger::FATAL
                     when :warn, "WARN", "warn" then ::Logger::WARN
                     when :info, "INFO", "info" then ::Logger::INFO
                     when :debug, "DEBUG", "debug" then ::Logger::DEBUG
                     else ::Logger::UNKNOWN
                     end

      return true if severity_int < ::Logger::ERROR

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
        msg_str = exception.message
      elsif progname.is_a?(Exception)
        exception = progname
        msg_str = message.to_s
      else
        msg_str = message.to_s
      end

      severity_str = (severity_int >= ::Logger::FATAL) ? "FATAL" : "ERROR"

      Logcore.capture(
        message: msg_str,
        severity: severity_str,
        exception: exception
      )
      true
    rescue => e
      true
    end

    def error(progname = nil, &block)
      add(::Logger::ERROR, nil, progname, &block)
    end

    def fatal(progname = nil, &block)
      add(::Logger::FATAL, nil, progname, &block)
    end

    def warn(progname = nil, &block); true; end
    def info(progname = nil, &block); true; end
    def debug(progname = nil, &block); true; end
    def unknown(progname = nil, &block)
      add(::Logger::UNKNOWN, nil, progname, &block)
    end
    def <<(msg); true; end
    def write(msg); true; end
    def close; true; end
  end
end
