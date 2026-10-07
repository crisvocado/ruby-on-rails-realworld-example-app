# frozen_string_literal: true

require "logger"

module Logcore
  class LoggerAdapter
    attr_accessor :level

    def initialize(config = nil, client = nil)
      @config = config || Logcore.config
      @client = client || Logcore.client
      @min_severity_level = Formatter.severity_level(@config.min_severity)
      @level = ::Logger::DEBUG
    end

    def add(severity, message = nil, progname = nil, &block)
      severity ||= ::Logger::UNKNOWN

      # Resolve message / progname / block
      if message.nil?
        if block_given?
          message = yield
        else
          message = progname
          progname = nil
        end
      end

      # Check severity threshold
      sev_name = Formatter.map_severity(severity)
      sev_level = Formatter.severity_level(sev_name)
      return true if sev_level < @min_severity_level

      exception = nil
      if message.is_a?(Exception)
        exception = message
      elsif progname.is_a?(Exception)
        exception = progname
      elsif defined?($!) && $!.is_a?(Exception)
        exception = $!
      end

      entry = Formatter.format(
        sev_name,
        message,
        @config,
        exception: exception
      )

      @client.enqueue(entry)
      true
    rescue Exception => e
      $stderr.puts("[logcore] LoggerAdapter#add error: #{e.message}")
      true
    end

    def debug(progname = nil, &block)
      add(::Logger::DEBUG, nil, progname, &block)
    end

    def info(progname = nil, &block)
      add(::Logger::INFO, nil, progname, &block)
    end

    def warn(progname = nil, &block)
      add(::Logger::WARN, nil, progname, &block)
    end

    def error(progname = nil, &block)
      add(::Logger::ERROR, nil, progname, &block)
    end

    def fatal(progname = nil, &block)
      add(::Logger::FATAL, nil, progname, &block)
    end

    def unknown(progname = nil, &block)
      add(::Logger::UNKNOWN, nil, progname, &block)
    end

    def format_message(severity, datetime, progname, msg)
      add(severity, msg, progname)
    end

    def puts(msg)
      add(::Logger::INFO, msg)
    end

    def write(msg)
      add(::Logger::INFO, msg)
    end

    def close
      # No-op
    end
  end
end
