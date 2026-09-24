# frozen_string_literal: true

require "digest"
require "json"
require "time"

module Logcore
  class Entry
    MAX_MESSAGE_LENGTH = 65_536
    MAX_LABELS_COUNT = 32
    MAX_LABEL_LENGTH = 1_024

    attr_reader :timestamp,
                :severity,
                :message,
                :service,
                :env,
                :insert_id,
                :trace,
                :error,
                :labels,
                :context

    def initialize(
      message:,
      severity: "ERROR",
      service: nil,
      env: nil,
      timestamp: nil,
      trace: nil,
      error: nil,
      labels: nil,
      context: nil
    )
      config = Logcore.configuration
      @timestamp = timestamp || Time.now.utc.iso8601(3)
      @severity = severity.to_s.upcase
      @severity = "ERROR" unless %w[ERROR FATAL].include?(@severity)
      @message = message.to_s[0...MAX_MESSAGE_LENGTH]
      @service = service || config.service
      @env = env || config.env
      @trace = trace
      @error = error
      @labels = sanitize_labels(labels)
      @context = sanitize_context(context)
      @insert_id = compute_insert_id
    end

    def to_h
      h = {
        "timestamp" => @timestamp,
        "severity" => @severity,
        "message" => @message,
        "service" => @service,
        "env" => @env,
        "insert_id" => @insert_id
      }
      h["trace"] = @trace if @trace && !@trace.empty?
      h["error"] = @error if @error && !@error.empty?
      h["labels"] = @labels if @labels && !@labels.empty?
      h["context"] = @context if @context && !@context.empty?
      h
    end

    def as_json(*args)
      to_h
    end

    def to_json(*args)
      JSON.generate(to_h)
    end

    private

    def compute_insert_id
      # sha256(timestamp | service | severity | message | canonical_json(context)) truncated to first 32 chars
      context_str = canonical_json(@context || {})
      raw = "#{@timestamp}|#{@service}|#{@severity}|#{@message}|#{context_str}"
      Digest::SHA256.hexdigest(raw)[0...32]
    end

    def canonical_json(obj)
      case obj
      when Hash
        sorted_pairs = obj.keys.sort_by(&:to_s).map do |k|
          "#{JSON.generate(k.to_s)}:#{canonical_json(obj[k])}"
        end
        "{#{sorted_pairs.join(',')}}"
      when Array
        "[#{obj.map { |v| canonical_json(v) }.join(',')}]"
      when String, Numeric, TrueClass, FalseClass, NilClass
        JSON.generate(obj)
      else
        JSON.generate(obj.to_s)
      end
    rescue
      "{}"
    end

    def sanitize_labels(raw_labels)
      return nil unless raw_labels.is_a?(Hash) && !raw_labels.empty?

      result = {}
      raw_labels.each_with_index do |(k, v), idx|
        break if idx >= MAX_LABELS_COUNT

        key = k.to_s[0...MAX_LABEL_LENGTH]
        val = v.to_s[0...MAX_LABEL_LENGTH]
        result[key] = val
      end
      result.empty? ? nil : result
    end

    def sanitize_context(raw_context)
      return nil unless raw_context.is_a?(Hash) && !raw_context.empty?

      raw_context
    end
  end
end
