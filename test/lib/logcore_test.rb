# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/logcore"

class LogcoreTest < ActiveSupport::TestCase
  setup do
    @captured_envelopes = []
    Logcore::Client.stub_sender = ->(envelope) { @captured_envelopes << envelope }
    Logcore.configuration.min_severity = "ERROR"
  end

  teardown do
    Logcore::Client.stub_sender = nil
    Logcore.client.instance_variable_set(:@consecutive_failures, 0)
  end

  test "entry conforms to wire shape and format rules" do
    sample_trace = {
      traceId: "4bf92f3577b34da6a3ce929d0e0e4736",
      spanId: "00f067aa0ba902b7",
      sampled: true
    }

    sample_error = begin
      raise StandardError, "Cannot read properties of undefined"
    rescue => e
      e
    end

    entry = Logcore::Entry.build(
      severity: Logger::ERROR,
      message: "checkout failed",
      exception: sample_error,
      trace: sample_trace,
      labels: { "region" => "us-east" },
      context: { "order_id" => "12345" }
    )

    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, entry["timestamp"])
    assert_equal "ERROR", entry["severity"]
    assert_equal "checkout failed", entry["message"]
    assert_match(/\A[a-z0-9][a-z0-9._-]{0,62}\z/, entry["service"])
    assert_includes %w[prod staging dev test local], entry["env"]
    assert_match(/\A[0-9a-f]{32}\z/, entry["insert_id"])

    # Trace assertions
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", entry.dig("trace", "traceId")
    assert_equal "00f067aa0ba902b7", entry.dig("trace", "spanId")
    assert_equal true, entry.dig("trace", "sampled")

    # Error assertions
    assert_equal "StandardError", entry.dig("error", "type")
    assert_equal "Cannot read properties of undefined", entry.dig("error", "message")
    assert entry.dig("error", "stack").is_a?(Array)
    first_frame = entry.dig("error", "stack", 0)
    assert first_frame
    assert first_frame.key?("function")
    assert first_frame.key?("file")
    assert first_frame.key?("line")
    assert first_frame.key?("column")
    assert first_frame.key?("inApp")
    assert_equal true, first_frame["inApp"]
  end

  test "insert_id is deterministic" do
    time_str = "2026-08-17T18:30:00.000Z"
    id1 = Logcore::Entry.compute_insert_id(time_str, "realworld", "ERROR", "test error", { "a" => 1 })
    id2 = Logcore::Entry.compute_insert_id(time_str, "realworld", "ERROR", "test error", { "a" => 1 })
    assert_equal id1, id2
    assert_equal 32, id1.length
    assert_match(/\A[0-9a-f]{32}\z/, id1)
  end

  test "client sends payload inside schema_version 1 envelope" do
    entry = Logcore::Entry.build(
      severity: Logger::ERROR,
      message: "critical failure"
    )

    Logcore.client.send_batch([entry])

    assert_equal 1, @captured_envelopes.size
    envelope = @captured_envelopes.first
    assert_equal 1, envelope["schema_version"]
    assert_equal 1, envelope["entries"].size
    assert_equal "critical failure", envelope["entries"][0]["message"]
  end

  test "severity floor ignores INFO and WARN logs" do
    Logcore.log(Logger::INFO, "Info message should be ignored")
    Logcore.log(Logger::WARN, "Warn message should be ignored")
    Logcore.flush

    assert_equal 0, @captured_envelopes.size

    Logcore.log(Logger::ERROR, "Error message captured")
    Logcore.flush

    assert_equal 1, @captured_envelopes.size
    assert_equal "Error message captured", @captured_envelopes.first["entries"][0]["message"]
  end

  test "circuit breaker trips after 10 consecutive failures" do
    client = Logcore::Client.new
    # Simulate 10 failures
    10.times do
      client.send(:record_failure)
    end

    assert_equal 10, client.consecutive_failures

    # send_batch should now drop entries
    result = client.send_batch([{ "message" => "test" }])
    assert_equal false, result
  end

  test "middleware parses W3C traceparent header" do
    middleware = Logcore::Middleware.new(->(env) {
      assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", Thread.current[:logcore_trace]["traceId"]
      assert_equal "00f067aa0ba902b7", Thread.current[:logcore_trace]["spanId"]
      assert_equal true, Thread.current[:logcore_trace]["sampled"]
      [200, {}, ["OK"]]
    })

    env = {
      "HTTP_TRACEPARENT" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      "action_dispatch.request_id" => "req-123"
    }

    middleware.call(env)
    assert_nil Thread.current[:logcore_trace]
  end

  test "logger broadcast forwards Rails.logger.error to Logcore" do
    Rails.logger.error("Broadcast error message")
    Logcore.flush

    assert_equal 1, @captured_envelopes.size
    assert_equal "Broadcast error message", @captured_envelopes.first["entries"][0]["message"]
  end

  test "clamps large messages, labels, and stack frames" do
    huge_message = "x" * 70_000
    huge_labels = 40.times.to_h { |i| ["key_#{i}", "v" * 1500] }

    entry = Logcore::Entry.build(
      severity: Logger::ERROR,
      message: huge_message,
      labels: huge_labels
    )

    assert_equal 65_536, entry["message"].length
    assert_equal 32, entry["labels"].size
    assert_equal 1_024, entry["labels"].values.first.length
  end

  test "exception cause chain extracts root cause backtrace" do
    root_cause = begin
      raise ArgumentError, "Root issue"
    rescue => e
      e
    end

    wrapped = begin
      begin
        raise root_cause
      rescue => r
        raise RuntimeError, "Wrapped issue"
      end
    rescue => w
      w
    end

    error_hash = Logcore::Entry.extract_error(wrapped)
    assert_equal "RuntimeError", error_hash["type"]
    assert_equal "Wrapped issue", error_hash["message"]
    assert error_hash["stack"].is_a?(Array)
    assert error_hash["stack"].size <= 50
    assert_equal true, error_hash["stack"].first["inApp"]
  end

  test "buffer drops oldest entries when buffer exceeds max capacity" do
    client = Logcore::Client.new
    buffer = Logcore::Buffer.new(client)

    1005.times do |i|
      buffer.push({ "id" => i })
    end

    # Size should cap at 1000
    assert_equal 1000, buffer.size

    # The first item should now be id 5, because 0..4 were shifted out
    queue = buffer.instance_variable_get(:@queue)
    assert_equal 5, queue.first["id"]
    assert_equal 1004, queue.last["id"]
  end
end
