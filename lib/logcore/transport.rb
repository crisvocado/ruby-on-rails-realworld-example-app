# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "thread"

module Logcore
  class Transport
    MAX_BUFFER_SIZE = 1_000
    BATCH_SIZE = 20
    MAX_BATCH_SIZE = 200
    FLUSH_INTERVAL = 5 # seconds
    MAX_RETRIES = 3
    MAX_CONSECUTIVE_FAILURES = 10

    def initialize(config)
      @config = config
      @buffer = []
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @consecutive_failures = 0
      @running = true
      @stub_handler = nil
      @worker_thread = nil
      start_worker
      at_exit { close(timeout: 3) rescue nil }
    end

    def enqueue(entry)
      return unless @config.enabled?
      return if @consecutive_failures >= MAX_CONSECUTIVE_FAILURES

      @mutex.synchronize do
        # Drop oldest if buffer is full
        @buffer.shift if @buffer.size >= MAX_BUFFER_SIZE
        @buffer << entry
        @condition.signal if @buffer.size >= BATCH_SIZE
      end
    rescue => e
      $stderr.puts "[Logcore] Enqueue error: #{e.message}"
    end

    def flush(timeout: 5)
      deadline = Time.now + timeout
      loop do
        entries_to_send = []
        @mutex.synchronize do
          return if @buffer.empty? || Time.now > deadline
          entries_to_send = @buffer.shift(MAX_BATCH_SIZE)
        end
        send_batch(entries_to_send) if entries_to_send.any?
      end
    rescue => e
      $stderr.puts "[Logcore] Flush error: #{e.message}"
    end

    def close(timeout: 5)
      @running = false
      @mutex.synchronize { @condition.broadcast }
      flush(timeout: timeout)
      @worker_thread&.join(timeout)
    rescue => e
      $stderr.puts "[Logcore] Close error: #{e.message}"
    end

    def stub!(&block)
      @stub_handler = block
    end

    def unstub!
      @stub_handler = nil
    end

    def buffer_size
      @mutex.synchronize { @buffer.size }
    end

    private

    def start_worker
      @worker_thread = Thread.new do
        Thread.current.name = "logcore-worker" if Thread.current.respond_to?(:name=)
        while @running
          entries_to_send = []
          @mutex.synchronize do
            if @buffer.size < BATCH_SIZE && @running
              @condition.wait(@mutex, FLUSH_INTERVAL)
            end
            break unless @running || !@buffer.empty?

            entries_to_send = @buffer.shift(MAX_BATCH_SIZE) unless @buffer.empty?
          end

          send_batch(entries_to_send) if entries_to_send.any?
        end
      end
    rescue => e
      $stderr.puts "[Logcore] Worker error: #{e.message}"
    end

    def send_batch(entries)
      return if entries.empty?

      if @stub_handler
        @stub_handler.call(entries)
        @consecutive_failures = 0
        return
      end

      endpoint = @config.endpoint
      api_key = @config.api_key

      if endpoint.nil? || endpoint.empty? || api_key.nil? || api_key.empty?
        # Drop batch if unconfigured
        return
      end

      payload = JSON.generate({
        schema_version: 1,
        entries: entries.map(&:to_h)
      })

      uri = URI.parse("#{endpoint.chomp('/')}/v1/logs")
      success = false
      attempt = 0

      while attempt <= MAX_RETRIES && !success
        begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 5
          http.read_timeout = 5

          req = Net::HTTP::Post.new(uri.request_uri)
          req["Content-Type"] = "application/json"
          req["x-api-key"] = api_key
          req.body = payload

          res = http.request(req)

          if res.is_a?(Net::HTTPSuccess)
            success = true
            @consecutive_failures = 0
            return
          elsif res.code == "429" || res.code.to_i >= 500
            # 429 or 5xx: retry with exponential backoff
            attempt += 1
            if attempt <= MAX_RETRIES
              backoff = (2**(attempt - 1)) * 0.25
              sleep(backoff)
            end
          else
            # Permanent rejection (400, 401, 403, 422, etc.): NOT retried
            $stderr.puts "[Logcore] Delivery rejected (#{res.code}): #{res.body}"
            @consecutive_failures = 0
            return
          end
        rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
          attempt += 1
          if attempt <= MAX_RETRIES
            backoff = (2**(attempt - 1)) * 0.25
            sleep(backoff)
          end
        rescue => e
          $stderr.puts "[Logcore] Unexpected transport error: #{e.message}"
          break
        end
      end

      unless success
        @consecutive_failures += 1
        if @consecutive_failures >= MAX_CONSECUTIVE_FAILURES
          $stderr.puts "[Logcore] Circuit breaker tripped after #{@consecutive_failures} consecutive failures. Clearing buffer."
          @mutex.synchronize { @buffer.clear }
        end
      end
    end
  end
end
