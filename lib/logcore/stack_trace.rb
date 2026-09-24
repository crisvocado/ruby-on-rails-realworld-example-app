# frozen_string_literal: true

module Logcore
  module StackTrace
    MAX_FRAMES = 50

    module_function

    def extract_error(exception, message = nil)
      return nil unless exception.is_a?(Exception) || (message && !message.empty?)

      if exception.is_a?(Exception)
        type = exception.class.name || "Error"
        msg = exception.message.to_s[0...65_536]
        frames = parse_exception_frames(exception)
      else
        type = "Error"
        msg = message.to_s[0...65_536]
        frames = capture_caller_frames
      end

      result = {
        "type" => type,
        "message" => msg
      }
      result["stack"] = frames if frames && !frames.empty?
      result
    end

    def parse_exception_frames(exception)
      # Follow cause chain to root cause
      chain = []
      curr = exception
      while curr
        chain.unshift(curr)
        curr = curr.respond_to?(:cause) ? curr.cause : nil
      end

      # Collect backtraces root-cause first
      raw_lines = []
      chain.each do |ex|
        if ex.respond_to?(:backtrace) && ex.backtrace
          raw_lines.concat(ex.backtrace)
        end
      end

      raw_lines.uniq!
      raw_lines = raw_lines[0...MAX_FRAMES]

      raw_lines.map { |line| parse_frame_line(line) }
    end

    def capture_caller_frames
      # Extract caller frames, skipping logcore/logger internal frames
      locs = caller_locations(3, MAX_FRAMES + 10) || []
      frames = []
      locs.each do |loc|
        path = loc.path || ""
        next if path.include?("/lib/logcore") || path.include?("/logger.rb")

        func = loc.base_label.to_s
        func = loc.label.to_s if func.empty?
        func = "<anon>" if func.empty?

        frames << {
          "function" => func,
          "file" => path,
          "line" => loc.lineno || 0,
          "column" => 0,
          "inApp" => in_app_path?(path)
        }
        break if frames.size >= MAX_FRAMES
      end
      frames
    end

    def parse_frame_line(line)
      str = line.to_s
      if str =~ /\A(.*?):(\d+)(?::in [`']?(.*?)'?)?\z/
        file = $1
        line_num = $2.to_i
        func = $3
        func = "<anon>" if func.nil? || func.empty?

        {
          "function" => func,
          "file" => file,
          "line" => line_num,
          "column" => 0,
          "inApp" => in_app_path?(file)
        }
      else
        {
          "function" => "<anon>",
          "file" => str,
          "line" => 0,
          "column" => 0,
          "inApp" => in_app_path?(str)
        }
      end
    end

    def in_app_path?(file_path)
      return false if file_path.nil? || file_path.empty?

      app_root = defined?(Rails.root) && Rails.root ? Rails.root.to_s : Dir.pwd

      if file_path.start_with?(app_root)
        rel = file_path.sub(/\A#{Regexp.escape(app_root)}\/?/, "")
        return false if rel.start_with?("vendor/", ".bundle/", "tmp/")
        return false if file_path.include?("/gems/") || file_path.include?("/bundle/")
        true
      elsif !file_path.start_with?("/") && !file_path.include?("/gems/") && !file_path.start_with?("vendor/")
        true
      else
        false
      end
    end
  end
end
