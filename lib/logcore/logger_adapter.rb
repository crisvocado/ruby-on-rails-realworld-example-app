# frozen_string_literal: true

require "logger"

module Logcore
  class LoggerAdapter < ::Logger
    def initialize
      super(nil)
      self.level = ::Logger::DEBUG # Filter in add() using Logcore.configuration.min_severity_int
    end

    def add(severity, message = nil, progname = nil, &block)
      severity ||= ::Logger::UNKNOWN

      # Self-exclusion check
      return true if Thread.current[:logcore_sending]

      # Severity floor check (ERROR and above by default)
      return true if severity < Logcore.configuration.min_severity_int

      # Extract message and exception
      exception = nil

      if message.nil?
        if block_given?
          message = yield
        else
          message = progname
          progname = nil
        end
      end

      if message.is_a?(Exception)
        exception = message
        message = exception.message
      elsif progname.is_a?(Exception)
        exception = progname
      end

      # Extract tags / labels from TaggedLogging if active
      labels = extract_tags

      # Extract trace and context from thread-local / Current storage
      trace = Thread.current[:logcore_trace]
      context = Thread.current[:logcore_context]

      entry = Logcore::Entry.build(
        severity: severity,
        message: message,
        exception: exception,
        trace: trace,
        labels: labels,
        context: context
      )

      Logcore.buffer.push(entry)
      true
    rescue StandardError => e
      $stderr.puts "[logcore] Logger adapter error: #{e.message}" rescue nil
      true
    end

    private

    def extract_tags
      if defined?(Rails) && Rails.logger.respond_to?(:formatter)
        formatter = Rails.logger.formatter
        if formatter.respond_to?(:current_tags)
          tags = formatter.current_tags
          if tags && !tags.empty?
            return tags.each_with_index.to_h { |tag, idx| ["tag_#{idx}", tag.to_s] }
          end
        end
      end
      nil
    rescue StandardError
      nil
    end
  end
end
