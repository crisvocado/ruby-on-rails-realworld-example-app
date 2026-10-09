# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/logcore"

class LogcoreTest < ActiveSupport::TestCase
  def setup
    Logcore.reset!
    @captured = []
    Logcore::Transport.capture_callback = lambda do |envelope|
      @captured << envelope
    end
  end

  def teardown
    Logcore.reset!
  end

  test "forwards Rails.logger.error to Logcore transport" do
    Rails.logger.error("Test error message")
    Logcore::Transport.flush

    assert_equal 1, @captured.size
    envelope = @captured.first
    assert_equal 1, envelope["schema_version"]
    assert_equal 1, envelope["entries"].size

    entry = envelope["entries"].first
    assert_equal "ERROR", entry["severity"]
    assert_equal "Test error message", entry["message"]
    assert_match(/\A[0-9a-f]{32}\z/, entry["insert_id"])
    assert_equal "test", entry["env"]
    assert_equal "realworld", entry["service"]
    assert_nil entry["trace"]
    assert_nil entry["error"]
  end

  test "does not forward logs below min severity" do
    Rails.logger.info("Info log")
    Rails.logger.debug("Debug log")
    Rails.logger.warn("Warn log")
    Logcore::Transport.flush

    assert_equal 0, @captured.size
  end

  test "captures exception details when logging an exception" do
    begin
      raise ArgumentError, "Invalid argument supplied"
    rescue => ex
      Rails.logger.error(ex)
    end
    Logcore::Transport.flush

    assert_equal 1, @captured.size
    entry = @captured.first["entries"].first
    assert_equal "ERROR", entry["severity"]
    assert_equal "Invalid argument supplied", entry["message"]
    assert_not_nil entry["error"]
    assert_equal "ArgumentError", entry["error"]["type"]
    assert_equal "Invalid argument supplied", entry["error"]["message"]
    assert entry["error"]["stack"].is_a?(Array)
    assert_operator entry["error"]["stack"].size, :>, 0

    top_frame = entry["error"]["stack"].first
    assert top_frame.key?("function")
    assert top_frame.key?("file")
    assert top_frame.key?("line")
    assert top_frame.key?("inApp")
    assert_equal true, top_frame["inApp"]
  end

  test "handles nested exception causes" do
    begin
      begin
        raise StandardError, "Root cause error"
      rescue => root_err
        raise RuntimeError, "Wrapper error"
      end
    rescue => wrapped_err
      Rails.logger.error(wrapped_err)
    end
    Logcore::Transport.flush

    assert_equal 1, @captured.size
    entry = @captured.first["entries"].first
    assert_equal "RuntimeError", entry["error"]["type"]
    assert_equal "Wrapper error", entry["error"]["message"]
    assert_operator entry["error"]["stack"].size, :>, 1
  end

  test "parses W3C traceparent header correctly" do
    header = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    parsed = Logcore::Formatter.parse_traceparent(header)

    assert_not_nil parsed
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", parsed["traceId"]
    assert_equal "00f067aa0ba902b7", parsed["spanId"]
    assert_equal true, parsed["sampled"]
  end

  test "omits trace when header is invalid or all zeros" do
    invalid_header = "00-00000000000000000000000000000000-0000000000000000-00"
    parsed = Logcore::Formatter.parse_traceparent(invalid_header)
    assert_nil parsed
  end

  test "deterministic insert_id generation" do
    entry1 = Logcore::Formatter.format_entry("ERROR", "Same message", nil)
    # Give exact same parameters
    id1 = entry1["insert_id"]
    id2 = Logcore::Formatter.send(:generate_insert_id, entry1["timestamp"], entry1["service"], entry1["severity"], entry1["message"], entry1["context"])
    assert_equal id1, id2
    assert_match(/\A[0-9a-f]{32}\z/, id1)
  end
end
