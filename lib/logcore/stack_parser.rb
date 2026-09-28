# frozen_string_literal: true

require "set"

module Logcore
  module StackParser
    FRAME_REGEX = /\A(?<file>.+?):(?<line>\d+)(?::(?<col>\d+))?(?::in\s+[`']?(?<func>.*?)['`]?)?\z/

    def self.parse_frame(line, app_root = default_app_root)
      return nil if line.nil? || line.empty?

      if line.strip =~ FRAME_REGEX
        file = $~[:file]
        line_num = $~[:line].to_i
        col_num = $~[:col] ? $~[:col].to_i : 0
        func = $~[:func]
        func = "<anonymous>" if func.nil? || func.empty?

        {
          function: func,
          file: file,
          line: line_num,
          column: col_num,
          inApp: in_app?(file, app_root)
        }
      else
        {
          function: "<unknown>",
          file: line.strip,
          line: 0,
          column: 0,
          inApp: false
        }
      end
    end

    def self.in_app?(file_path, app_root = default_app_root)
      return false if file_path.nil? || file_path.empty?

      clean_path = file_path.to_s
      return false if clean_path.start_with?("(", "[") # e.g. (eval) or [internal:core]

      if app_root && !app_root.empty? && clean_path.start_with?(app_root)
        relative = clean_path.sub(/\A#{Regexp.escape(app_root)}\/?/, "")
        !relative.match?(/\A(vendor|\.bundle|bundle|node_modules|tmp|bin)\//)
      elsif !clean_path.start_with?("/")
        !clean_path.match?(/\A(vendor|\.bundle|bundle|node_modules|tmp|bin)\//)
      else
        false
      end
    end

    def self.parse_exception(exception, app_root = default_app_root)
      return nil unless exception.is_a?(Exception)

      # Follow exception chain to root cause for backtrace
      root = exception
      visited = Set.new([root.object_id])
      while root.cause && root.cause.is_a?(Exception) && !visited.include?(root.cause.object_id)
        root = root.cause
        visited << root.object_id
      end

      raw_backtrace = (root.backtrace && !root.backtrace.empty?) ? root.backtrace : (exception.backtrace || [])
      frames = raw_backtrace.map { |line| parse_frame(line, app_root) }.compact

      {
        type: exception.class.name || "Error",
        message: exception.message.to_s[0...65536],
        stack: frames.first(50)
      }
    end

    def self.parse_backtrace(backtrace_lines, app_root = default_app_root)
      return [] if backtrace_lines.nil? || backtrace_lines.empty?

      frames = backtrace_lines.map { |line| parse_frame(line.to_s, app_root) }.compact
      frames.first(50)
    end

    def self.default_app_root
      defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
    end
  end
end
