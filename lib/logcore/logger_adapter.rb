# frozen_string_literal: true

require "logger"

module Logcore
  module LoggerAdapter
    def self.attach(logger)
      return if logger.nil? || logger.singleton_class.ancestors.include?(Interceptor)

      logger.singleton_class.prepend(Interceptor)
    rescue => e
      $stderr.puts "[Logcore] Failed to attach to logger: #{e.message}"
    end

    module Interceptor
      def add(severity, message = nil, progname = nil, &block)
        result = super(severity, message, progname, &block)

        begin
          sev_int = LoggerAdapter.to_severity_int(severity)
          if sev_int && sev_int >= Logcore.config.min_severity
            LoggerAdapter.process_log(sev_int, message, progname, block, self)
          end
        rescue => e
          $stderr.puts "[Logcore] Logger interception error: #{e.message}"
        end

        result
      end
    end

    def self.to_severity_int(severity)
      case severity
      when Integer then severity
      when :debug, "DEBUG", "debug" then ::Logger::DEBUG
      when :info, "INFO", "info" then ::Logger::INFO
      when :warn, "WARN", "warn", "warning" then ::Logger::WARN
      when :error, "ERROR", "error" then ::Logger::ERROR
      when :fatal, "FATAL", "fatal" then ::Logger::FATAL
      when :unknown, "UNKNOWN", "unknown" then ::Logger::UNKNOWN
      else ::Logger::ERROR
      end
    end

    def self.severity_to_string(sev_int)
      case sev_int
      when ::Logger::DEBUG then "DEBUG"
      when ::Logger::INFO then "INFO"
      when ::Logger::WARN then "WARN"
      when ::Logger::ERROR then "ERROR"
      when ::Logger::FATAL then "FATAL"
      when ::Logger::UNKNOWN then "CRITICAL"
      else "ERROR"
      end
    end

    def self.process_log(severity_int, message, progname, block, logger)
      msg_text, exception = extract_message_and_exception(message, progname, block)

      error_data = nil
      if exception
        error_data = StackParser.parse_exception(exception)
      elsif msg_text.include?("\n")
        # Check if message contains a backtrace string
        parsed = extract_error_from_text(msg_text)
        if parsed
          error_data = parsed[:error]
          msg_text = parsed[:message] if parsed[:message]
        end
      end

      # Extract tags if TaggedLogging is used
      labels = {}
      if logger && logger.respond_to?(:formatter) && logger.formatter.respond_to?(:current_tags)
        tags = logger.formatter.current_tags
        labels["tags"] = tags.join(", ") if tags && !tags.empty?
      end

      entry = Entry.new(
        severity: severity_to_string(severity_int),
        message: msg_text,
        error: error_data,
        labels: labels.empty? ? nil : labels
      )

      Logcore.transport.enqueue(entry)
    end

    def self.extract_message_and_exception(message, progname, block)
      actual_msg = nil
      exception = nil

      if block
        val = block.call rescue nil
        if val.is_a?(Exception)
          exception = val
          actual_msg = val.message
        else
          actual_msg = val.to_s
        end
      elsif message.is_a?(Exception)
        exception = message
        actual_msg = message.message
      elsif progname.is_a?(Exception)
        exception = progname
        actual_msg = progname.message
      elsif message
        actual_msg = message.to_s
      elsif progname
        actual_msg = progname.to_s
      else
        actual_msg = ""
      end

      [actual_msg || "", exception]
    end

    def self.extract_error_from_text(text)
      lines = text.lines.map(&:strip)
      return nil if lines.empty?

      first_line = lines.first
      if first_line =~ /\A([A-Z][a-zA-Z0-9_:]*(?:Error|Exception)?):\s*(.*)\z/
        err_type = $1
        err_msg = $2
        bt_lines = lines[1..-1].select { |l| l =~ StackParser::FRAME_REGEX || l =~ /\Afrom / }
        if bt_lines.any?
          frames = bt_lines.map { |l| StackParser.parse_frame(l.sub(/\Afrom /, "")) }.compact
          return {
            message: first_line,
            error: {
              type: err_type,
              message: err_msg,
              stack: frames.first(50)
            }
          }
        end
      end
      nil
    end
  end
end
