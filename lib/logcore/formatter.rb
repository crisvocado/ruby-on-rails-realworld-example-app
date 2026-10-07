# frozen_string_literal: true

require "digest"
require "json"
require "set"
require "time"

module Logcore
  class Formatter
    SEVERITY_MAP = {
      0 => "DEBUG",
      1 => "INFO",
      2 => "WARNING",
      3 => "ERROR",
      4 => "CRITICAL",
      5 => "ERROR",
      "DEBUG" => "DEBUG",
      "INFO" => "INFO",
      "WARN" => "WARNING",
      "WARNING" => "WARNING",
      "ERROR" => "ERROR",
      "FATAL" => "CRITICAL",
      "UNKNOWN" => "ERROR"
    }.freeze

    SEVERITY_LEVELS = {
      "DEBUG" => 0,
      "INFO" => 1,
      "NOTICE" => 1,
      "WARNING" => 2,
      "ERROR" => 3,
      "CRITICAL" => 4,
      "ALERT" => 5,
      "EMERGENCY" => 6
    }.freeze

    def self.format(severity_input, raw_message, config, exception: nil, context: nil, labels: nil, trace_context: nil)
      severity = map_severity(severity_input)
      timestamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
      service = config.service
      env = config.env

      # Resolve exception if raw_message is an Exception or explicitly passed
      if raw_message.is_a?(Exception)
        exception ||= raw_message
        msg = "#{raw_message.class}: #{raw_message.message}"
      elsif raw_message.is_a?(String)
        msg = raw_message
      elsif raw_message.respond_to?(:to_s)
        msg = raw_message.to_s
      else
        msg = "Log event"
      end

      # Strip terminal control codes or trailing newlines if needed
      msg = msg.strip
      msg = "Unknown error" if msg.empty?
      # Clamp message to 65536 chars
      msg = msg[0...65536]

      # Canonical json for context in insert_id derivation
      canonical_ctx = canonical_json(context)
      insert_id_seed = "#{timestamp}|#{service}|#{severity}|#{msg}|#{canonical_ctx}"
      insert_id = Digest::SHA256.hexdigest(insert_id_seed)[0...32]

      entry = {
        "timestamp" => timestamp,
        "severity" => severity,
        "message" => msg,
        "service" => service,
        "env" => env,
        "insert_id" => insert_id
      }

      # Trace context (W3C traceparent)
      trace = format_trace(trace_context || Thread.current[:logcore_trace_context])
      entry["trace"] = trace if trace

      # Error object
      error_obj = format_error(exception)
      entry["error"] = error_obj if error_obj

      # Labels (max 32 entries, clamped values)
      clamped_labels = format_labels(labels)
      entry["labels"] = clamped_labels if clamped_labels

      # Context
      if context.is_a?(Hash) && !context.empty?
        entry["context"] = context
      end

      entry
    end

    def self.map_severity(sev)
      SEVERITY_MAP[sev] || SEVERITY_MAP[sev.to_s.upcase] || "ERROR"
    end

    def self.severity_level(sev_string)
      SEVERITY_LEVELS[sev_string] || 3
    end

    def self.format_trace(trace_ctx)
      return nil unless trace_ctx.is_a?(Hash)

      trace_id = trace_ctx[:traceId] || trace_ctx["traceId"] || trace_ctx[:trace_id] || trace_ctx["trace_id"]
      return nil unless trace_id.is_a?(String) && trace_id =~ /\A[0-9a-f]{32}\z/ && trace_id != "00000000000000000000000000000000"

      span_id = trace_ctx[:spanId] || trace_ctx["spanId"] || trace_ctx[:span_id] || trace_ctx["span_id"]
      sampled = trace_ctx[:sampled] || trace_ctx["sampled"]

      obj = { "traceId" => trace_id }
      if span_id.is_a?(String) && span_id =~ /\A[0-9a-f]{16}\z/
        obj["spanId"] = span_id
      end
      obj["sampled"] = !!sampled unless sampled.nil?
      obj
    end

    def self.format_error(exception)
      return nil unless exception.is_a?(Exception)

      app_root = defined?(Rails) && Rails.root ? Rails.root.to_s : nil
      frames = extract_exception_stack(exception, app_root)

      error_data = {
        "type" => exception.class.name.to_s[0...256],
        "message" => (exception.message || "").to_s[0...65536]
      }
      error_data["stack"] = frames unless frames.empty?
      error_data
    end

    def self.extract_exception_stack(exception, app_root)
      # Follow exception chain to root cause
      chain = []
      current = exception
      seen = Set.new
      while current && !seen.include?(current)
        seen.add(current)
        chain << current
        current = current.cause
      end

      # Root cause innermost first: reverse chain
      frames = []
      chain.reverse_each do |ex|
        next unless ex.backtrace.is_a?(Array)
        ex.backtrace.each do |line|
          frame = parse_backtrace_frame(line, app_root)
          frames << frame if frame
          break if frames.size >= 50
        end
        break if frames.size >= 50
      end

      frames[0...50]
    end

    def self.parse_backtrace_frame(line_str, app_root)
      return nil unless line_str.is_a?(String)

      # Ruby backtrace line format: "/path/to/file.rb:123:in 'method_name'" or "/path/to/file.rb:123:in `method_name'"
      if line_str =~ /\A(.+?):(\d+)(?::in [`']?(.*?)'?)?\z/
        file = $1
        line = $2.to_i
        func = $3
        func = "<anonymous>" if func.nil? || func.empty?
      else
        file = line_str
        line = nil
        func = "<anonymous>"
      end

      in_app = false
      if app_root && file.start_with?(app_root)
        rel_path = file.sub(/\A#{Regexp.escape(app_root)}\/?/, "")
        in_app = !(rel_path.start_with?("vendor/") || rel_path.start_with?(".bundle/") || rel_path.include?("/gems/"))
      elsif !file.start_with?("/") && !file.start_with?("<")
        in_app = !(file.start_with?("vendor/") || file.start_with?(".bundle/") || file.include?("/gems/"))
      end

      {
        "function" => func.to_s[0...256],
        "file" => file.to_s[0...1024],
        "line" => line,
        "inApp" => in_app
      }
    end

    def self.format_labels(labels)
      return nil unless labels.is_a?(Hash) && !labels.empty?

      result = {}
      labels.each do |k, v|
        key_str = k.to_s
        next unless key_str =~ /\A[a-zA-Z0-9_-]{1,64}\z/
        result[key_str] = v.to_s[0...1024]
        break if result.size >= 32
      end

      result.empty? ? nil : result
    end

    def self.canonical_json(obj)
      return "" if obj.nil? || (obj.respond_to?(:empty?) && obj.empty?)
      begin
        JSON.generate(sort_keys_recursively(obj))
      rescue StandardError
        obj.to_s
      end
    end

    def self.sort_keys_recursively(obj)
      case obj
      when Hash
        obj.keys.sort_by(&:to_s).each_with_object({}) do |k, h|
          h[k.to_s] = sort_keys_recursively(obj[k])
        end
      when Array
        obj.map { |item| sort_keys_recursively(item) }
      else
        obj
      end
    end
  end
end
