# frozen_string_literal: true

require "test_helper"

class LogcoreTest < ActiveSupport::TestCase
  test "formats basic error log entry without exception" do
    config = Logcore::Config.new
    entry = Logcore::Formatter.format(Logger::ERROR, "Simple error message", config)

    assert_equal "ERROR", entry["severity"]
    assert_equal "Simple error message", entry["message"]
    assert_equal "test", entry["env"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, entry["timestamp"])
    assert_match(/\A[0-9a-f]{32}\z/, entry["insert_id"])
    assert_nil entry["error"]
    assert_nil entry["trace"]
    assert_nil entry["labels"]
    assert_nil entry["context"]
    assert_nil entry["service_id"]
    assert_nil entry["source_project"]
    assert_nil entry["fingerprint"]
  end

  test "formats error with exception and stack" do
    config = Logcore::Config.new
    begin
      raise ArgumentError, "invalid argument test"
    rescue => ex
      entry = Logcore::Formatter.format(Logger::ERROR, ex, config)
    end

    assert_equal "ERROR", entry["severity"]
    assert_equal "ArgumentError: invalid argument test", entry["message"]
    assert_not_nil entry["error"]
    assert_equal "ArgumentError", entry["error"]["type"]
    assert_equal "invalid argument test", entry["error"]["message"]
    assert entry["error"]["stack"].is_a?(Array)
    assert_not_empty entry["error"]["stack"]
    first_frame = entry["error"]["stack"].first
    assert first_frame["inApp"]
    assert_equal __FILE__, first_frame["file"]
  end

  test "formats trace context when present" do
    config = Logcore::Config.new
    trace_ctx = {
      traceId: "4bf92f3577b34da6a3ce929d0e0e4736",
      spanId: "00f067aa0ba902b7",
      sampled: true
    }
    entry = Logcore::Formatter.format(Logger::ERROR, "Trace test", config, trace_context: trace_ctx)

    assert_not_nil entry["trace"]
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", entry["trace"]["traceId"]
    assert_equal "00f067aa0ba902b7", entry["trace"]["spanId"]
    assert_equal true, entry["trace"]["sampled"]
  end

  test "omits invalid or all-zero trace context" do
    config = Logcore::Config.new
    invalid_trace = {
      traceId: "00000000000000000000000000000000",
      spanId: "0000000000000000"
    }
    entry = Logcore::Formatter.format(Logger::ERROR, "Invalid trace test", config, trace_context: invalid_trace)
    assert_nil entry["trace"]
  end

  test "middleware extracts W3C traceparent" do
    app = ->(env) {
      ctx = Thread.current[:logcore_trace_context]
      assert_not_nil ctx
      assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", ctx[:traceId]
      assert_equal "00f067aa0ba902b7", ctx[:spanId]
      assert_equal true, ctx[:sampled]
      [200, { "Content-Type" => "text/plain" }, ["OK"]]
    }

    middleware = Logcore::Middleware.new(app)
    env = {
      "HTTP_TRACEPARENT" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    }

    status, _, _ = middleware.call(env)
    assert_equal 200, status
    assert_nil Thread.current[:logcore_trace_context]
  end

  test "logger broadcast intercepts Rails.logger.error" do
    captured = []
    Logcore.stub_transport! { |envelope| captured << envelope }

    Rails.logger.error("Broadcast test error")
    Logcore.flush(timeout: 2.0)

    assert_equal 1, captured.size
    envelope = captured.first
    assert_equal 1, envelope["schema_version"]
    assert_equal 1, envelope["entries"].size
    assert_equal "Broadcast test error", envelope["entries"].first["message"]
  ensure
    Logcore.restore_transport!
  end
end
