# frozen_string_literal: true

require "logger"

module Logcore
  class LoggerAdapter
    attr_reader :transport, :config

    def initialize(transport, config)
      @transport = transport
      @config = config
    end

    def add(severity, message = nil, progname = nil, &block)
      return true unless @config.enabled?
      return true if Thread.current[:logcore_internal]

      sev_int = normalize_severity(severity)
      return true if sev_int < @config.min_severity_level

      # Resolve message content
      msg = message
      if msg.nil?
        if block_given?
          msg = yield
        else
          msg = progname
        end
      end

      return true if msg.nil?

      sev_str = severity_to_string(sev_int)

      entry = Logcore::Entry.build(
        severity: sev_str,
        message: msg,
        config: @config,
        trace: Logcore.current_trace,
        labels: Logcore.current_labels,
        context: Logcore.current_context
      )

      @transport.enqueue(entry) if entry
      true
    rescue => e
      $stderr.puts "[Logcore] Adapter error: #{e.message}" if $DEBUG
      true
    end

    def <<(msg)
      add(::Logger::ERROR, msg)
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

    def debug(*); true; end
    def info(*); true; end
    def warn(*); true; end

    def close; end
    def level=(*); end
    def formatter=(*); end

    def silence(temporary_level = ::Logger::ERROR)
      yield self if block_given?
    end

    private

    def normalize_severity(sev)
      return sev if sev.is_a?(Integer)

      case sev.to_s.upcase
      when "DEBUG" then ::Logger::DEBUG
      when "INFO"  then ::Logger::INFO
      when "WARN", "WARNING" then ::Logger::WARN
      when "ERROR" then ::Logger::ERROR
      when "FATAL" then ::Logger::FATAL
      when "UNKNOWN" then ::Logger::UNKNOWN
      else ::Logger::ERROR
      end
    rescue
      ::Logger::ERROR
    end

    def severity_to_string(level)
      case level
      when ::Logger::DEBUG then "DEBUG"
      when ::Logger::INFO  then "INFO"
      when ::Logger::WARN  then "WARN"
      when ::Logger::ERROR then "ERROR"
      when ::Logger::FATAL then "FATAL"
      when ::Logger::UNKNOWN then "ERROR"
      else "ERROR"
      end
    end
  end
end
