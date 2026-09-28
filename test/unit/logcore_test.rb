# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/logcore"

class LogcoreTest < ActiveSupport::TestCase
  setup do
    @emitted = []
    Logcore.stub_transport! do |batch|
      @emitted.concat(batch)
    end
  end

  teardown do
    Logcore.unstub_transport!
    Logcore::Context.clear!
  end

  test "config normalizes env and service name" do
    config = Logcore::Config.new
    assert_includes %w[prod staging dev test local], config.env
    assert_match(/\A[a-z0-9][a-z0-9._-]{0,62}\z/, config.service)
  end

  test "traceparent parser extracts traceId, spanId and sampled flag" do
    header = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    trace = Logcore::Trace.from_traceparent(header)

    assert_not_nil trace
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", trace[:traceId]
    assert_equal "00f067aa0ba902b7", trace[:spanId]
    assert_equal true, trace[:sampled]
    assert_equal header, Logcore::Trace.to_traceparent(trace)
  end

  test "trace generator generates valid trace object" do
    trace = Logcore::Trace.generate
    assert_equal 32, trace[:traceId].length
    assert_equal 16, trace[:spanId].length
    assert_equal true, trace[:sampled]
  end

  test "stack parser parses backtrace into frames with inApp flag" do
    ex = nil
    begin
      raise ArgumentError, "invalid argument test"
    rescue => e
      ex = e
    end

    parsed = Logcore::StackParser.parse_exception(ex)
    assert_not_nil parsed
    assert_equal "ArgumentError", parsed[:type]
    assert_equal "invalid argument test", parsed[:message]
    assert parsed[:stack].is_a?(Array)
    assert parsed[:stack].any?

    first_frame = parsed[:stack].first
    assert first_frame.key?(:function)
    assert first_frame.key?(:file)
    assert first_frame.key?(:line)
    assert first_frame.key?(:column)
    assert first_frame.key?(:inApp)
    assert_equal true, first_frame[:inApp]
  end

  test "entry builds golden-compatible json payload" do
    entry = Logcore::Entry.new(
      timestamp: Time.utc(2026, 8, 17, 18, 30, 0),
      severity: "ERROR",
      message: "checkout failed",
      service: "todo-frontend",
      env: "dev",
      trace: {
        traceId: "4bf92f3577b34da6a3ce929d0e0e4736",
        spanId: "00f067aa0ba902b7",
        sampled: true
      },
      error: {
        type: "TypeError",
        message: "Cannot read properties of undefined (reading 'total')",
        stack: [
          {
            function: "checkout",
            file: "https://app.example.com/assets/index-a1b2c3.js",
            line: 1,
            column: 48213,
            inApp: true
          }
        ]
      }
    )

    data = entry.to_h
    assert_equal "2026-08-17T18:30:00.000Z", data["timestamp"]
    assert_equal "ERROR", data["severity"]
    assert_equal "checkout failed", data["message"]
    assert_equal "todo-frontend", data["service"]
    assert_equal "dev", data["env"]
    assert_match(/\A[0-9a-f]{32}\z/, data["insert_id"])
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", data["trace"]["traceId"]
    assert_equal "TypeError", data["error"]["type"]
    assert_equal true, data["error"]["stack"].first["inApp"]
  end

  test "Rails.logger intercepts error logs" do
    @emitted.clear
    Rails.logger.error("Test error for Logcore interception")
    Logcore.flush(timeout: 2)

    assert_equal 1, @emitted.size
    entry = @emitted.first
    assert_equal "ERROR", entry.severity
    assert_equal "Test error for Logcore interception", entry.message
    assert_match(/\A[0-9a-f]{32}\z/, entry.insert_id)
  end

  test "Rails.logger ignores info logs" do
    @emitted.clear
    Rails.logger.info("This should not be captured by Logcore")
    Logcore.flush(timeout: 2)

    assert_empty @emitted
  end

  test "Rails.logger intercepts exceptions" do
    @emitted.clear
    begin
      raise RuntimeError, "Unhandled failure occurred"
    rescue => e
      Rails.logger.error(e)
    end
    Logcore.flush(timeout: 2)

    assert_equal 1, @emitted.size
    entry = @emitted.first
    assert_equal "ERROR", entry.severity
    assert_equal "Unhandled failure occurred", entry.message
    assert_not_nil entry.error
    assert_equal "RuntimeError", entry.error["type"]
    assert entry.error["stack"].any?
  end

  test "middleware binds traceparent and injects response header" do
    app = ->(env) { [200, { "Content-Type" => "text/plain" }, ["OK"]] }
    middleware = Logcore::Middleware.new(app)

    env = {
      "HTTP_TRACEPARENT" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    }

    status, headers, body = middleware.call(env)
    assert_equal 200, status
    assert_equal "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", headers["traceparent"]
  end
end
