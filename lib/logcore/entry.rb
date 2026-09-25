# frozen_string_literal: true

require "digest"
require "json"
require "time"

module Logcore
  class Entry
    BACKTRACE_REGEX = /\A(.*?):(\d+)(?::in\s+[`']?(.*?)'?)?\z/
    MAX_MESSAGE_LENGTH = 65_536
    MAX_LABEL_COUNT = 32
    MAX_LABEL_VALUE_LENGTH = 1_024
    MAX_STACK_FRAMES = 50

    SEVERITY_NAMES = {
      0 => "DEBUG",
      1 => "INFO",
      2 => "WARN",
      3 => "ERROR",
      4 => "FATAL",
      5 => "UNKNOWN"
    }.freeze

    def self.build(severity:, message:, exception: nil, trace: nil, labels: nil, context: nil, configuration: nil)
      config = configuration || Logcore.configuration
      now = Time.now.utc
      timestamp = now.iso8601(3)
      sev_str = format_severity(severity)
      svc = config.normalized_service
      env_str = config.normalized_env

      # Extract message string and exception if message was an Exception
      if message.is_a?(Exception) && exception.nil?
        exception = message
        message = exception.message
      end

      msg_str = (message || exception&.message || "").to_s[0, MAX_MESSAGE_LENGTH]
      ctx = sanitize_context(context)
      lbls = sanitize_labels(labels)
      err = extract_error(exception)
      trc = sanitize_trace(trace)

      # Deterministic insert_id from timestamp | service | severity | message | canonical_json(context)
      insert_id = compute_insert_id(timestamp, svc, sev_str, msg_str, ctx)

      entry = {
        "timestamp" => timestamp,
        "severity" => sev_str,
        "message" => msg_str,
        "service" => svc,
        "env" => env_str,
        "insert_id" => insert_id
      }

      entry["trace"] = trc if trc
      entry["error"] = err if err
      entry["labels"] = lbls if lbls && !lbls.empty?
      entry["context"] = ctx if ctx && !ctx.empty?

      entry
    end

    def self.compute_insert_id(timestamp, service, severity, message, context)
      context_str = if context && !context.empty?
                      begin
                        JSON.generate(context.sort.to_h)
                      rescue StandardError
                        "{}"
                      end
                    else
                      "{}"
                    end
      seed = "#{timestamp}|#{service}|#{severity}|#{message}|#{context_str}"
      Digest::SHA256.hexdigest(seed)[0, 32]
    end

    def self.format_severity(severity)
      case severity
      when Integer
        SEVERITY_NAMES[severity] || "UNKNOWN"
      when Symbol, String
        severity.to_s.upcase
      else
        "UNKNOWN"
      end
    end

    def self.extract_error(exception)
      return nil unless exception.is_a?(Exception)

      # Traverse exception chain to follow causes (root cause first)
      chain = []
      curr = exception
      visited = Set.new
      while curr.is_a?(Exception) && !visited.include?(curr)
        visited.add(curr)
        chain << curr
        curr = curr.cause
      end

      # Root cause is last in cause chain; its backtrace represents where the failure originated
      root = chain.last
      raw_backtrace = (root&.backtrace && !root.backtrace.empty?) ? root.backtrace : exception.backtrace
      raw_backtrace ||= caller

      frames = parse_backtrace(raw_backtrace)

      {
        "type" => exception.class.name || "Exception",
        "message" => exception.message.to_s[0, MAX_MESSAGE_LENGTH],
        "stack" => frames[0, MAX_STACK_FRAMES]
      }
    end

    def self.parse_backtrace(lines)
      return [] unless lines.is_a?(Array)

      rails_root = defined?(Rails.root) && Rails.root ? Rails.root.to_s : Dir.pwd

      lines.filter_map do |line|
        next unless line.is_a?(String)

        if line =~ BACKTRACE_REGEX
          file = $1
          lineno = $2.to_i
          func = $3.to_s.empty? ? "<anon>" : $3

          in_app = file.start_with?(rails_root) &&
                   !file.include?("/vendor/") &&
                   !file.include?("/bundle/") &&
                   !file.include?("/.bundle/") &&
                   !file.include?("/gems/")

          {
            "function" => func,
            "file" => file,
            "line" => lineno,
            "column" => 0,
            "inApp" => in_app
          }
        end
      end
    end

    def self.sanitize_labels(labels)
      return nil unless labels.is_a?(Hash) && !labels.empty?

      result = {}
      labels.first(MAX_LABEL_COUNT).each do |k, v|
        result[k.to_s] = v.to_s[0, MAX_LABEL_VALUE_LENGTH]
      end
      result
    end

    def self.sanitize_context(context)
      return nil unless context.is_a?(Hash) && !context.empty?

      # Ensure context is JSON-serializable
      begin
        JSON.parse(JSON.generate(context))
      rescue StandardError
        context.transform_values(&:to_s)
      end
    end

    def self.sanitize_trace(trace)
      return nil unless trace.is_a?(Hash)

      trace_id = trace[:traceId] || trace["traceId"]
      span_id = trace[:spanId] || trace["spanId"]
      sampled = trace[:sampled] || trace["sampled"]

      return nil unless trace_id && span_id

      {
        "traceId" => trace_id.to_s,
        "spanId" => span_id.to_s,
        "sampled" => sampled.nil? ? true : !!sampled
      }
    end
  end
end
