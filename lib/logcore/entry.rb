# frozen_string_literal: true

require "json"
require "digest"
require "time"

module Logcore
  class Entry
    MAX_MESSAGE_LENGTH = 65_536
    MAX_LABELS_COUNT = 32
    MAX_LABEL_STRING_LENGTH = 1_024
    MAX_STACK_FRAMES = 50

    BACKTRACE_REGEX = /\A(.*?):(\d+)(?::in [`'](.*?)'?)?\z/.freeze

    class << self
      def build(severity:, message:, config:, trace: nil, error: nil, labels: nil, context: nil, timestamp: nil)
        ts = timestamp || Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
        sev = severity.to_s.upcase
        svc = config.service
        env = config.env

        # Extract message and exception if message is an Exception
        extracted_error = error
        msg_str = ""

        if message.is_a?(Exception)
          extracted_error ||= extract_error_from_exception(message)
          msg_str = "#{message.class}: #{message.message}"
        elsif message.is_a?(Hash)
          msg_str = message[:message] || message["message"] || message.to_json
        else
          msg_str = message.to_s
        end

        # If message contains backtrace or error was passed as string
        if extracted_error.nil? && message.is_a?(String) && message.include?("\n")
          extracted_error = extract_error_from_string(message)
        end

        # Clamp message length
        msg_str = msg_str[0...MAX_MESSAGE_LENGTH] if msg_str.length > MAX_MESSAGE_LENGTH

        # Canonical context for insert_id
        clamped_context = clean_hash(context)
        context_json = canonical_json(clamped_context)

        # Deterministic 32-char insert_id: sha256(timestamp | service | severity | message | canonical_json(context))[:32]
        insert_id = Digest::SHA256.hexdigest("#{ts}|#{svc}|#{sev}|#{msg_str}|#{context_json}")[0...32]

        entry = {
          "timestamp" => ts,
          "severity" => sev,
          "message" => msg_str,
          "service" => svc,
          "env" => env,
          "insert_id" => insert_id
        }

        # Trace
        if trace && trace["traceId"] && trace["spanId"]
          entry["trace"] = {
            "traceId" => trace["traceId"],
            "spanId" => trace["spanId"],
            "sampled" => !!trace["sampled"]
          }
        end

        # Error
        if extracted_error && extracted_error["type"]
          entry["error"] = extracted_error
        end

        # Labels
        clamped_labels = clean_labels(labels)
        entry["labels"] = clamped_labels if clamped_labels && !clamped_labels.empty?

        # Context
        entry["context"] = clamped_context if clamped_context && !clamped_context.empty?

        entry
      end

      def extract_error_from_exception(exception)
        return nil unless exception.is_a?(Exception)

        # Keep type and message of the raised exception
        error_type = exception.class.name || "Error"
        error_msg = exception.message.to_s

        # Follow exception cause chain to root to gather innermost frames
        root_exception = find_root_cause(exception)
        raw_backtrace = root_exception.backtrace || exception.backtrace || caller_locations(3).map(&:to_s) rescue []

        frames = parse_backtrace(raw_backtrace)

        {
          "type" => error_type,
          "message" => error_msg,
          "stack" => frames[0...MAX_STACK_FRAMES]
        }
      end

      def extract_error_from_string(text)
        lines = text.lines.map(&:strip)
        return nil if lines.size < 2

        # Check if first line resembles an error, e.g. "StandardError: something" or "RuntimeError (something):"
        first_line = lines.first
        type = "Error"
        msg = first_line

        if first_line =~ /\A([A-Z][a-zA-Z0-9_:]+)(?::|\s+\()(.*?)(?:\)|\z)/
          type = Regexp.last_match(1)
          msg = Regexp.last_match(2).strip
        end

        bt_lines = lines[1..].select { |l| l =~ BACKTRACE_REGEX }
        return nil if bt_lines.empty?

        frames = parse_backtrace(bt_lines)
        return nil if frames.empty?

        {
          "type" => type,
          "message" => msg,
          "stack" => frames[0...MAX_STACK_FRAMES]
        }
      end

      def parse_backtrace(backtrace_lines)
        return [] unless backtrace_lines.is_a?(Array)

        rails_root = defined?(Rails.root) && Rails.root ? Rails.root.to_s : Dir.pwd

        frames = []
        backtrace_lines.each do |line|
          if line =~ BACKTRACE_REGEX
            file = Regexp.last_match(1)
            line_no = Regexp.last_match(2).to_i
            func = Regexp.last_match(3) || "<anon>"

            in_app = file.start_with?(rails_root) &&
                     !file.include?("/vendor/") &&
                     !file.include?("/.bundle/") &&
                     !file.include?("/gems/")

            frames << {
              "function" => func,
              "file" => file,
              "line" => line_no,
              "column" => 0,
              "inApp" => in_app
            }
          end
        end

        frames
      end

      def canonical_json(obj)
        case obj
        when Hash
          pairs = obj.keys.map(&:to_s).sort.map do |k|
            val = obj[k] || obj[k.to_sym]
            "#{k.to_json}:#{canonical_json(val)}"
          end
          "{#{pairs.join(',')}}"
        when Array
          "[#{obj.map { |x| canonical_json(x) }.join(',')}]"
        when String, Numeric, TrueClass, FalseClass, NilClass
          obj.to_json
        else
          obj.to_s.to_json
        end
      end

      private

      def find_root_cause(err)
        current = err
        visited = Set.new
        while current.respond_to?(:cause) && current.cause && !visited.include?(current.cause.object_id)
          visited.add(current.object_id)
          current = current.cause
        end
        current
      end

      def clean_labels(raw_labels)
        return nil unless raw_labels.is_a?(Hash) && !raw_labels.empty?

        cleaned = {}
        raw_labels.each_with_index do |(k, v), idx|
          break if idx >= MAX_LABELS_COUNT

          key_str = k.to_s[0...MAX_LABEL_STRING_LENGTH]
          val_str = v.to_s[0...MAX_LABEL_STRING_LENGTH]
          cleaned[key_str] = val_str
        end
        cleaned
      end

      def clean_hash(raw_hash)
        return {} unless raw_hash.is_a?(Hash)

        cleaned = {}
        raw_hash.each do |k, v|
          cleaned[k.to_s] = v
        end
        cleaned
      end
    end
  end
end
