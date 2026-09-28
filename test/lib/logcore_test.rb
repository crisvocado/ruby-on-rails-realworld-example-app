# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/logcore"

class LogcoreTest < ActiveSupport::TestCase
  test "config initializes with defaults and normalizes environment" do
    config = Logcore::Config.new(
      url: "https://example.com/gateway",
      key: "test-key-123",
      service: "My App",
      env: "production",
      min_severity: "error"
    )

    assert_equal "https://example.com/gateway", config.url
    assert_equal "test-key-123", config.key
    assert_equal "my-app", config.service
    assert_equal "prod", config.env
    assert_equal "ERROR", config.min_severity
    assert_equal ::Logger::ERROR, config.min_severity_level
    assert config.enabled?
  end

  test "config normalizes various environment names" do
    assert_equal "dev", Logcore::Config.new(env: "development").env
    assert_equal "dev", Logcore::Config.new(env: "dev").env
    assert_equal "prod", Logcore::Config.new(env: "production").env
    assert_equal "prod", Logcore::Config.new(env: "prod").env
    assert_equal "staging", Logcore::Config.new(env: "staging").env
    assert_equal "test", Logcore::Config.new(env: "test").env
    assert_equal "local", Logcore::Config.new(env: "local").env
  end

  test "entry build conforms to wire shape and golden entry" do
    config = Logcore::Config.new(
      service: "test-service",
      env: "dev"
    )

    trace = {
      "traceId" => "4bf92f3577b34da6a3ce929d0e0e4736",
      "spanId" => "00f067aa0ba902b7",
      "sampled" => true
    }

    entry = Logcore::Entry.build(
      severity: "ERROR",
      message: "Something failed",
      config: config,
      trace: trace,
      timestamp: "2026-08-17T18:30:00.000Z"
    )

    assert_equal "2026-08-17T18:30:00.000Z", entry["timestamp"]
    assert_equal "ERROR", entry["severity"]
    assert_equal "Something failed", entry["message"]
    assert_equal "test-service", entry["service"]
    assert_equal "dev", entry["env"]
    assert_match(/\A[0-9a-f]{32}\z/, entry["insert_id"])
    assert_equal trace, entry["trace"]
    assert_nil entry["service_id"]
    assert_nil entry["source_project"]
  end

  test "entry insert_id is deterministic" do
    config = Logcore::Config.new(service: "test-service", env: "dev")
    ts = "2026-08-17T18:30:00.000Z"

    entry1 = Logcore::Entry.build(
      severity: "ERROR",
      message: "Order processing failed",
      config: config,
      timestamp: ts,
      context: { order_id: 123 }
    )

    entry2 = Logcore::Entry.build(
      severity: "ERROR",
      message: "Order processing failed",
      config: config,
      timestamp: ts,
      context: { order_id: 123 }
    )

    assert_equal entry1["insert_id"], entry2["insert_id"]
  end

  test "entry parses exception stack frames with innermost frame first" do
    config = Logcore::Config.new(service: "test-service", env: "dev")

    err = nil
    begin
      raise ArgumentError, "invalid argument provided"
    rescue => e
      err = e
    end

    entry = Logcore::Entry.build(
      severity: "ERROR",
      message: err,
      config: config
    )

    assert_equal "ArgumentError: invalid argument provided", entry["message"]
    assert_not_nil entry["error"]
    assert_equal "ArgumentError", entry["error"]["type"]
    assert_equal "invalid argument provided", entry["error"]["message"]
    assert entry["error"]["stack"].is_a?(Array)
    assert entry["error"]["stack"].size > 0

    first_frame = entry["error"]["stack"].first
    assert first_frame.key?("function")
    assert first_frame.key?("file")
    assert first_frame.key?("line")
    assert first_frame.key?("column")
    assert first_frame.key?("inApp")
    assert_equal true, first_frame["inApp"] # Inside test file (within Rails root)
  end

  test "entry unwinds exception cause chain to root" do
    config = Logcore::Config.new(service: "test-service", env: "dev")

    wrapped = nil
    begin
      begin
        raise TypeError, "original root error"
      rescue => root_err
        raise RuntimeError, "wrapped service error"
      end
    rescue => e
      wrapped = e
    end

    entry = Logcore::Entry.build(
      severity: "ERROR",
      message: wrapped,
      config: config
    )

    # Keeps type and message of raised exception
    assert_equal "RuntimeError", entry["error"]["type"]
    assert_equal "wrapped service error", entry["error"]["message"]
    assert entry["error"]["stack"].size > 0
  end

  test "entry clamps long message, labels, and stack" do
    config = Logcore::Config.new(service: "test-service", env: "dev")

    long_msg = "A" * 70_000
    labels = {}
    40.times { |i| labels["key_#{i}"] = "val_#{i}_#{"x" * 2000}" }

    entry = Logcore::Entry.build(
      severity: "ERROR",
      message: long_msg,
      labels: labels,
      config: config
    )

    assert_equal 65_536, entry["message"].length
    assert_equal 32, entry["labels"].size
    assert entry["labels"].all? { |k, v| k.length <= 1024 && v.length <= 1024 }
  end

  test "transport drops oldest when buffer cap is reached" do
    config = Logcore::Config.new(buffer_cap: 3, batch_size: 10, flush_interval: 60)
    transport = Logcore::Transport.new(config)

    3.times { |i| transport.enqueue({ "msg" => "entry #{i}" }) }
    assert_equal 3, transport.queue.size
    assert_equal "entry 0", transport.queue.first["msg"]

    transport.enqueue({ "msg" => "entry 3" })
    assert_equal 3, transport.queue.size
    assert_equal "entry 1", transport.queue.first["msg"]
    assert_equal "entry 3", transport.queue.last["msg"]

    transport.stop
  end

  test "transport circuit breaker trips after 10 consecutive failures" do
    config = Logcore::Config.new(circuit_breaker_threshold: 3, max_retries: 0)
    transport = Logcore::Transport.new(config)

    # Mock post_payload to raise network error
    transport.define_singleton_method(:post_payload) do |_body|
      raise Errno::ECONNREFUSED, "Connection refused"
    end

    assert_equal false, transport.circuit_broken

    transport.send_batch([{ "msg" => "1" }])
    transport.send_batch([{ "msg" => "2" }])
    assert_equal 2, transport.consecutive_failures
    assert_equal false, transport.circuit_broken

    transport.send_batch([{ "msg" => "3" }])
    assert_equal 3, transport.consecutive_failures
    assert_equal true, transport.circuit_broken

    # Enqueue should now reject entries
    assert_equal false, transport.enqueue({ "msg" => "4" })

    transport.stop
  end

  test "logger adapter filters below ERROR" do
    config = Logcore::Config.new(min_severity: "ERROR")
    transport = Logcore::Transport.new(config)
    adapter = Logcore::LoggerAdapter.new(transport, config)

    adapter.add(::Logger::DEBUG, "debug message")
    adapter.add(::Logger::INFO, "info message")
    adapter.add(::Logger::WARN, "warn message")

    assert_equal 0, transport.queue.size

    adapter.add(::Logger::ERROR, "error message")
    assert_equal 1, transport.queue.size
    assert_equal "error message", transport.queue.first["message"]

    adapter.add(::Logger::FATAL, "fatal message")
    assert_equal 2, transport.queue.size
    assert_equal "fatal message", transport.queue.last["message"]

    transport.stop
  end

  test "middleware parses W3C traceparent header" do
    app = ->(env) { [200, { "Content-Type" => "text/plain" }, ["OK"]] }
    middleware = Logcore::Middleware.new(app)

    traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    env = {
      "HTTP_TRACEPARENT" => traceparent,
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/api/articles"
    }

    captured_trace = nil
    test_app = ->(e) do
      captured_trace = Logcore.current_trace
      [200, { "Content-Type" => "text/plain" }, ["OK"]]
    end

    Logcore::Middleware.new(test_app).call(env)

    assert_not_nil captured_trace
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", captured_trace["traceId"]
    assert_equal "00f067aa0ba902b7", captured_trace["spanId"]
    assert_equal true, captured_trace["sampled"]

    # Ensure context was cleared after request
    assert_nil Logcore.current_trace
  end
end
