# frozen_string_literal: true

require "digest"
require "json"
require "time"

module Logcore
  module Formatter
    TRACEPARENT_REGEX = /\A([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/i.freeze
    LABEL_KEY_REGEX = /\A[a-zA-Z0-9_-]{1,64}\z/.freeze

    class << self
      def format_entry(severity_str, message, exception = nil, trace: nil, context: nil, labels: nil)
        config = Logcore.configuration
        timestamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
        severity = map_severity(severity_str)
        service = config.service
        env = config.env

        msg_str = (message.presence || (exception ? exception.message : "")).to_s
        msg_str = msg_str[0...65536]
        msg_str = "Log entry" if msg_str.empty?

        ctx = sanitize_context(context || (defined?(Current) ? Current.context : nil))
        insert_id = generate_insert_id(timestamp, service, severity, msg_str, ctx)

        entry = {
          "timestamp" => timestamp,
          "severity" => severity,
          "message" => msg_str,
          "service" => service,
          "env" => env,
          "insert_id" => insert_id
        }

        # Handle trace context
        active_trace = trace || (defined?(Current) ? Current.trace : nil)
        if active_trace && valid_trace?(active_trace)
          entry["trace"] = format_trace(active_trace)
        end

        # Handle exception / error details
        if exception.is_a?(Exception)
          entry["error"] = format_error(exception)
        end

        # Handle labels
        active_labels = sanitize_labels(labels || (defined?(Current) ? Current.labels : nil))
        entry["labels"] = active_labels if active_labels && !active_labels.empty?

        # Handle context
        entry["context"] = ctx if ctx && !ctx.empty?

        entry
      end

      def parse_traceparent(header)
        return nil if header.nil? || header.to_s.strip.empty?

        match = TRACEPARENT_REGEX.match(header.to_s.strip)
        return nil unless match

        _version, trace_id, span_id, flags = match.captures
        return nil if trace_id == "00000000000000000000000000000000"

        span_val = span_id == "0000000000000000" ? nil : span_id.downcase
        sampled_val = (flags.to_i(16) & 1) == 1

        {
          "traceId" => trace_id.downcase,
          "spanId" => span_val,
          "sampled" => sampled_val
        }.compact
      end

      private

      def map_severity(severity)
        case severity.to_s.upcase
        when "DEBUG" then "DEBUG"
        when "INFO" then "INFO"
        when "WARN", "WARNING" then "WARNING"
        when "ERROR" then "ERROR"
        when "FATAL", "CRITICAL" then "CRITICAL"
        when "ALERT" then "ALERT"
        when "EMERGENCY" then "EMERGENCY"
        else "ERROR"
        end
      end

      def generate_insert_id(timestamp, service, severity, message, context)
        ctx_json = canonical_json(context)
        Digest::SHA256.hexdigest("#{timestamp}|#{service}|#{severity}|#{message}|#{ctx_json}")[0...32]
      end

      def canonical_json(obj)
        return "" if obj.nil? || (obj.respond_to?(:empty?) && obj.empty?)

        case obj
        when Hash
          "{" + obj.keys.sort.map { |k| "#{k.to_s.dump}:#{canonical_json(obj[k])}" }.join(",") + "}"
        when Array
          "[" + obj.map { |v| canonical_json(v) }.join(",") + "]"
        else
          JSON.generate(obj)
        end
      rescue
        ""
      end

      def valid_trace?(trace)
        return false unless trace.is_a?(Hash)
        trace_id = trace["traceId"] || trace[:traceId] || trace["trace_id"] || trace[:trace_id]
        trace_id.is_a?(String) && trace_id.match?(/\A[0-9a-f]{32}\z/i) && trace_id != "00000000000000000000000000000000"
      end

      def format_trace(trace)
        trace_id = (trace["traceId"] || trace[:traceId] || trace["trace_id"] || trace[:trace_id]).to_s.downcase
        span_id = trace["spanId"] || trace[:spanId] || trace["span_id"] || trace[:span_id]
        sampled = trace.key?("sampled") ? trace["sampled"] : trace[:sampled]

        res = { "traceId" => trace_id }
        res["spanId"] = span_id.to_s.downcase if span_id.present? && span_id.to_s.match?(/\A[0-9a-f]{16}\z/i)
        res["sampled"] = !!sampled unless sampled.nil?
        res
      end

      def format_error(exception)
        # Collect exception chain (root cause first)
        chain = []
        curr = exception
        while curr.is_a?(Exception)
          chain << curr
          curr = curr.cause
        end

        # Innermost / root cause first for stack frames
        raw_frames = []
        chain.reverse_each do |ex|
          if ex.respond_to?(:backtrace_locations) && ex.backtrace_locations
            ex.backtrace_locations.each do |loc|
              raw_frames << {
                function: loc.label || loc.base_label || "<unknown>",
                file: loc.path,
                line: loc.lineno
              }
            end
          elsif ex.backtrace
            ex.backtrace.each do |line|
              if (m = line.match(/\A(.+?):(\d+)(?::in [`'](.+?)['\\])?\z/))
                raw_frames << {
                  file: m[1],
                  line: m[2].to_i,
                  function: m[3] || "<unknown>"
                }
              end
            end
          end
        end

        rails_root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd

        parsed_stack = raw_frames.map do |frame|
          file_str = frame[:file].to_s
          is_in_app = file_str.start_with?(rails_root) &&
                      !file_str.include?("/vendor/") &&
                      !file_str.include?("/.bundle/") &&
                      !file_str.include?("/bundle/") &&
                      !file_str.include?("/gems/")

          {
            "function" => frame[:function].to_s[0...256],
            "file" => file_str[0...1024],
            "line" => frame[:line].is_a?(Integer) ? frame[:line] : nil,
            "inApp" => is_in_app
          }
        end

        parsed_stack = parsed_stack.first(50)

        {
          "type" => exception.class.name.to_s[0...256],
          "message" => (exception.message || "").to_s[0...65536],
          "stack" => parsed_stack
        }
      end

      def sanitize_labels(labels)
        return nil unless labels.is_a?(Hash)

        cleaned = {}
        labels.each do |k, v|
          key_str = k.to_s
          next unless key_str.match?(LABEL_KEY_REGEX)
          cleaned[key_str] = v.to_s[0...1024]
          break if cleaned.size >= 32
        end
        cleaned
      end

      def sanitize_context(context)
        return nil unless context.is_a?(Hash)
        context
      end
    end
  end
end
