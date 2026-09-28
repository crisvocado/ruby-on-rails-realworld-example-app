# frozen_string_literal: true

require "digest"
require "json"
require "time"

module Logcore
  class Entry
    attr_reader :timestamp, :severity, :message, :service, :env, :insert_id, :trace, :error, :labels, :context

    MAX_MESSAGE_LENGTH = 65_536
    MAX_LABELS_COUNT = 32
    MAX_LABEL_VALUE_LENGTH = 1_024

    def initialize(
      timestamp: nil,
      severity: "ERROR",
      message: "",
      service: nil,
      env: nil,
      trace: nil,
      error: nil,
      labels: nil,
      context: nil
    )
      @timestamp = format_timestamp(timestamp || Time.now.utc)
      @severity = normalize_severity(severity)
      @message = sanitize_message(message)
      @service = service || Logcore.config.service
      @env = env || Logcore.config.env
      @trace = sanitize_trace(trace || Context.current_trace)
      @error = sanitize_error(error)
      @labels = sanitize_labels(labels)
      @context = sanitize_context(context || Context.current_context)
      @insert_id = compute_insert_id
    end

    def to_h
      hash = {
        "timestamp" => @timestamp,
        "severity" => @severity,
        "message" => @message,
        "service" => @service,
        "env" => @env,
        "insert_id" => @insert_id
      }

      hash["trace"] = @trace if @trace
      hash["error"] = @error if @error
      hash["labels"] = @labels if @labels && !@labels.empty?
      hash["context"] = @context if @context && !@context.empty?

      hash
    end

    def as_json(*_args)
      to_h
    end

    def to_json(*_args)
      JSON.generate(to_h)
    end

    private

    def format_timestamp(ts)
      t = ts.is_a?(Time) ? ts.utc : Time.parse(ts.to_s).utc
      t.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
    end

    def normalize_severity(sev)
      case sev.to_s.upcase.strip
      when "FATAL" then "FATAL"
      when "CRITICAL" then "CRITICAL"
      when "WARN", "WARNING" then "WARN"
      when "INFO" then "INFO"
      when "DEBUG" then "DEBUG"
      else "ERROR"
      end
    end

    def sanitize_message(msg)
      str = msg.to_s
      str.length > MAX_MESSAGE_LENGTH ? str[0...MAX_MESSAGE_LENGTH] : str
    end

    def sanitize_trace(tr)
      return nil unless tr.is_a?(Hash)
      trace_id = tr[:traceId] || tr["traceId"]
      span_id = tr[:spanId] || tr["spanId"]
      return nil unless trace_id && span_id
      sampled = tr.key?(:sampled) ? tr[:sampled] : tr["sampled"]
      {
        "traceId" => trace_id.to_s,
        "spanId" => span_id.to_s,
        "sampled" => !!sampled
      }
    end

    def sanitize_error(err)
      return nil unless err.is_a?(Hash)
      err_type = err[:type] || err["type"]
      return nil unless err_type
      err_msg = err.key?(:message) ? err[:message] : err["message"]
      raw_stack = err[:stack] || err["stack"] || []
      {
        "type" => err_type.to_s,
        "message" => (err_msg || "").to_s[0...MAX_MESSAGE_LENGTH],
        "stack" => raw_stack.first(50).map do |f|
          {
            "function" => (f[:function] || f["function"] || "<unknown>").to_s,
            "file" => (f[:file] || f["file"] || "").to_s,
            "line" => (f[:line] || f["line"] || 0).to_i,
            "column" => (f[:column] || f["column"] || 0).to_i,
            "inApp" => !!(f.key?(:inApp) ? f[:inApp] : f["inApp"])
          }
        end
      }
    end

    def sanitize_labels(lbls)
      return nil if lbls.nil? || !lbls.is_a?(Hash) || lbls.empty?
      cleaned = {}
      lbls.first(MAX_LABELS_COUNT).each do |k, v|
        cleaned[k.to_s] = v.to_s[0...MAX_LABEL_VALUE_LENGTH]
      end
      cleaned
    end

    def sanitize_context(ctx)
      return nil if ctx.nil? || !ctx.is_a?(Hash) || ctx.empty?
      ctx
    end

    def compute_insert_id
      ctx_str = canonical_json(@context)
      raw = "#{@timestamp}|#{@service}|#{@severity}|#{@message}|#{ctx_str}"
      Digest::SHA256.hexdigest(raw)[0...32]
    end

    def canonical_json(obj)
      return "" if obj.nil? || (obj.respond_to?(:empty?) && obj.empty?)
      sorted = deep_sort_keys(obj)
      JSON.generate(sorted)
    rescue => _e
      ""
    end

    def deep_sort_keys(obj)
      case obj
      when Hash
        obj.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          val = obj.key?(key) ? obj[key] : obj[key.to_sym]
          result[key] = deep_sort_keys(val)
        end
      when Array
        obj.map { |v| deep_sort_keys(v) }
      else
        obj
      end
    end
  end
end
