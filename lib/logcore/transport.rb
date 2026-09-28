# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "thread"

module Logcore
  class Transport
    attr_reader :config, :queue, :consecutive_failures, :circuit_broken

    def initialize(config)
      @config = config
      @queue = []
      @mutex = Mutex.new
      @resource = ConditionVariable.new
      @running = true
      @consecutive_failures = 0
      @circuit_broken = false
      @last_flush_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      @endpoint_uri = URI(normalize_endpoint(@config.url))

      start_worker_thread
      setup_at_exit_hook
    end

    def endpoint_url
      @endpoint_uri.to_s
    end

    def enqueue(entry)
      return false unless entry && @config.enabled?
      return false if @circuit_broken

      @mutex.synchronize do
        if @queue.size >= @config.buffer_cap
          @queue.shift # Drop oldest
        end
        @queue.push(entry)

        if @queue.size >= @config.batch_size
          @resource.signal
        end
      end
      true
    rescue => e
      $stderr.puts "[Logcore] Enqueue error: #{e.message}" if $DEBUG
      false
    end

    def flush(timeout: 5.0)
      return if @queue.empty? && @mutex.synchronize { @queue.empty? }

      batches_to_send = []
      @mutex.synchronize do
        until @queue.empty?
          batch = @queue.shift(@config.max_batch_size)
          batches_to_send << batch unless batch.empty?
        end
      end

      batches_to_send.each do |batch|
        send_batch(batch)
      end
    end

    def stop(timeout: 5.0)
      @running = false
      @mutex.synchronize { @resource.broadcast }
      if @worker_thread && @worker_thread.alive?
        @worker_thread.join(timeout)
      end
    end

    def flush_and_stop(timeout: 5.0)
      flush(timeout: timeout)
      stop(timeout: timeout)
    end

    def send_batch(entries)
      return true if entries.nil? || entries.empty?
      return false if @circuit_broken
      return false unless @config.enabled?

      payload = {
        "schema_version" => 1,
        "entries" => entries
      }
      body_json = JSON.generate(payload)

      attempt = 0
      max_retries = @config.max_retries

      while attempt <= max_retries
        begin
          response = post_payload(body_json)

          code = response.code.to_i
          if code >= 200 && code < 300
            # Success: reset circuit breaker & failure counter
            @consecutive_failures = 0
            @circuit_broken = false
            return true
          elsif code == 429 || (code >= 500 && code <= 599)
            # Retryable server / rate limit error
            attempt += 1
            if attempt <= max_retries
              backoff = (2**attempt) * 0.25 # 0.5s, 1.0s, 2.0s
              sleep(backoff)
            else
              record_failure("HTTP #{code}: #{response.body}")
              return false
            end
          else
            # Permanent client error (400, 401, 403, 404, 422, etc.): DO NOT RETRY
            record_failure("Permanent rejection (#{code}): #{response.body}")
            return false
          end
        rescue => e
          # Network error / timeout
          attempt += 1
          if attempt <= max_retries
            backoff = (2**attempt) * 0.25
            sleep(backoff)
          else
            record_failure("Network error: #{e.class} - #{e.message}")
            return false
          end
        end
      end

      false
    end

    private

    def normalize_endpoint(raw_url)
      url = raw_url.to_s.strip
      url = "https://logcore-dev-352942961463.us-east4.run.app" if url.empty?
      url = url.chomp("/")
      url += "/v1/logs" unless url.end_with?("/v1/logs")
      url
    end

    def post_payload(body_json)
      # Self-exclusion: avoid recursive instrumentation
      Thread.current[:logcore_internal] = true

      http = Net::HTTP.new(@endpoint_uri.host, @endpoint_uri.port)
      http.use_ssl = (@endpoint_uri.scheme == "https")
      http.open_timeout = 5.0
      http.read_timeout = 10.0

      request = Net::HTTP::Post.new(@endpoint_uri.request_uri)
      request["Content-Type"] = "application/json"
      request["x-api-key"] = @config.key.to_s if @config.key

      request.body = body_json
      http.request(request)
    ensure
      Thread.current[:logcore_internal] = false
    end

    def record_failure(reason)
      @consecutive_failures += 1
      $stderr.puts "[Logcore] #{reason}"

      if @consecutive_failures >= @config.circuit_breaker_threshold
        @circuit_broken = true
        $stderr.puts "[Logcore] Circuit breaker tripped after #{@consecutive_failures} consecutive flush failures. Emptying buffer."
        @mutex.synchronize { @queue.clear }
      end
    end

    def start_worker_thread
      @worker_thread = Thread.new do
        Thread.current.name = "logcore-worker" if Thread.current.respond_to?(:name=)

        while @running
          batch = nil
          @mutex.synchronize do
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            time_since_flush = now - @last_flush_time

            if @queue.size < @config.batch_size && time_since_flush < @config.flush_interval
              remaining_time = [@config.flush_interval - time_since_flush, 0.1].max
              @resource.wait(@mutex, remaining_time)
            end

            unless @queue.empty?
              batch = @queue.shift(@config.max_batch_size)
              @last_flush_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end

          if batch && !batch.empty?
            send_batch(batch)
          end
        end
      end
      @worker_thread.abort_on_exception = false
    end

    def setup_at_exit_hook
      at_exit do
        flush_and_stop(timeout: 3.0) rescue nil
      end
    end
  end
end
