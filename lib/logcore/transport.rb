# frozen_string_literal: true

require "net/http"
require "json"
require "thread"

module Logcore
  class Transport
    attr_reader :config, :buffer, :consecutive_failures

    def initialize(config = Logcore.configuration)
      @config = config
      @buffer = []
      @buffer_mutex = Mutex.new
      @buffer_cv = ConditionVariable.new
      @consecutive_failures = 0
      @running = false
      @worker_thread = nil
      start_worker
    end

    def enqueue(entry)
      return unless @config.enabled?

      @buffer_mutex.synchronize do
        # Buffer cap: 1000 entries; drop oldest when full
        if @buffer.size >= @config.buffer_capacity
          @buffer.shift
        end
        @buffer.push(entry)

        # Signal worker if batch threshold reached
        if @buffer.size >= @config.batch_size
          @buffer_cv.signal
        end
      end
    rescue => e
      # Never crash caller
    end

    def flush(timeout: 5.0)
      deadline = Time.now + timeout
      loop do
        batch = nil
        @buffer_mutex.synchronize do
          if @buffer.empty?
            return true
          end
          batch = @buffer.shift(@config.max_batch_size)
        end

        break if batch.nil? || batch.empty?

        send_batch(batch)

        break if Time.now >= deadline
      end
      true
    rescue => e
      false
    end

    def shutdown(timeout: 5.0)
      @running = false
      @buffer_mutex.synchronize do
        @buffer_cv.broadcast
      end
      flush(timeout: timeout)
      if @worker_thread && @worker_thread.alive?
        @worker_thread.join(timeout)
      end
    end

    def send_entry_sync(entry)
      send_batch([entry])
    end

    def send_batch(batch)
      return if batch.empty?

      # Circuit breaker check
      if @consecutive_failures >= @config.circuit_breaker_threshold
        $stderr.puts "[Logcore] Circuit breaker active (#{@consecutive_failures} failures). Dropping #{batch.size} entries."
        return
      end

      envelope = {
        "schema_version" => 1,
        "entries" => batch.map(&:to_h)
      }
      payload = JSON.generate(envelope)

      uri = @config.ingest_uri
      retries = 0

      loop do
        response = perform_http_post(uri, payload)

        if response.nil?
          # Network or connection error
          retries += 1
          if retries <= @config.max_retries
            sleep((2**retries) * 0.25)
            next
          else
            record_failure
            return
          end
        end

        code = response.code.to_i
        if code >= 200 && code < 300
          # Success
          record_success
          return
        elsif code == 429 || code >= 500
          # Retryable error
          retries += 1
          if retries <= @config.max_retries
            sleep((2**retries) * 0.25)
            next
          else
            record_failure
            return
          end
        else
          # Permanent rejection (4xx except 429)
          $stderr.puts "[Logcore] Permanent rejection (#{response.code}): #{response.body}"
          record_failure(permanent: true)
          return
        end
      end
    rescue => e
      record_failure
    end

    def record_success
      @consecutive_failures = 0
    end

    def record_failure(permanent: false)
      @consecutive_failures += 1
      if @consecutive_failures >= @config.circuit_breaker_threshold
        @buffer_mutex.synchronize do
          @buffer.clear
        end
        $stderr.puts "[Logcore] Circuit breaker activated: buffer cleared after #{@consecutive_failures} consecutive failures."
      end
    end

    private

    def start_worker
      return if @running

      @running = true
      @worker_thread = Thread.new do
        Thread.current.name = "logcore-worker" if Thread.current.respond_to?(:name=)
        worker_loop
      end
    end

    def worker_loop
      while @running
        batch = nil
        @buffer_mutex.synchronize do
          while @running && @buffer.size < @config.batch_size
            @buffer_cv.wait(@buffer_mutex, @config.flush_interval_seconds)
            break if @buffer.any?
          end

          if @buffer.any?
            batch = @buffer.shift(@config.max_batch_size)
          end
        end

        if batch && !batch.empty?
          send_batch(batch)
        end
      end
    rescue => e
      $stderr.puts "[Logcore] Worker thread error: #{e.message}"
    end

    def perform_http_post(uri, payload)
      # Self-exclusion: mark thread so HTTP interceptors do not intercept logcore POST
      Thread.current[:logcore_internal_request] = true

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 5
      http.read_timeout = 5

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["x-api-key"] = @config.api_key if @config.api_key

      request.body = payload
      http.request(request)
    rescue => e
      nil
    ensure
      Thread.current[:logcore_internal_request] = nil
    end
  end
end
