# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "thread"

module Logcore
  class Client
    BUFFER_CAP = 1000
    BATCH_SIZE = 20
    MAX_BATCH_SIZE = 200
    FLUSH_INTERVAL = 5.0
    MAX_RETRIES = 3
    CIRCUIT_BREAKER_LIMIT = 10

    attr_reader :config, :ingest_url

    def initialize(config)
      @config = config
      @ingest_url = config.ingest_url
      @queue = []
      @mutex = Mutex.new
      @resource = ConditionVariable.new
      @running = true
      @consecutive_failures = 0
      @stub_handler = nil
      @worker = Thread.new { worker_loop }
      @worker.name = "logcore-worker" if @worker.respond_to?(:name=)

      at_exit do
        flush(timeout: 5.0)
        stop
      end
    end

    def enqueue(entry)
      return unless @running
      return unless entry.is_a?(Hash)

      @mutex.synchronize do
        # Buffer cap: drop oldest entries if full
        while @queue.size >= BUFFER_CAP
          @queue.shift
        end

        @queue.push(entry)
        @resource.signal if @queue.size >= BATCH_SIZE
      end
    end

    def stub_transport!(&block)
      @stub_handler = block
    end

    def restore_transport!
      @stub_handler = nil
    end

    def flush(timeout: 5.0)
      start_time = Time.now
      loop do
        batch = nil
        @mutex.synchronize do
          if @queue.empty?
            return true
          end
          batch = @queue.shift(MAX_BATCH_SIZE)
        end

        process_batch(batch) if batch && !batch.empty?

        if Time.now - start_time > timeout
          break
        end
      end
    end

    def stop
      @running = false
      @mutex.synchronize { @resource.broadcast }
      @worker.join(1.0) rescue nil
    end

    private

    def worker_loop
      while @running
        batch = nil
        @mutex.synchronize do
          if @queue.empty?
            @resource.wait(@mutex, FLUSH_INTERVAL)
          end
          unless @queue.empty?
            batch = @queue.shift(MAX_BATCH_SIZE)
          end
        end

        if batch && !batch.empty?
          process_batch(batch)
        end
      end
    rescue Exception => e
      $stderr.puts("[logcore] Worker thread encountered error: #{e.message}")
    end

    def process_batch(batch)
      return if batch.empty?

      # Circuit breaker check
      if @consecutive_failures >= CIRCUIT_BREAKER_LIMIT
        @mutex.synchronize { @queue.clear }
        $stderr.puts("[logcore] Circuit breaker open (#{CIRCUIT_BREAKER_LIMIT} consecutive failures). Dropping batch.")
        return
      end

      envelope = {
        "schema_version" => 1,
        "entries" => batch
      }

      # If stub handler is registered (for local probe / test validation)
      if @stub_handler
        begin
          @stub_handler.call(envelope)
          @consecutive_failures = 0
        rescue Exception => e
          $stderr.puts("[logcore] Stub handler error: #{e.message}")
        end
        return
      end

      # If transport is disabled or no api key, drop without error
      unless @config.enabled
        return
      end

      api_key = @config.api_key
      if api_key.nil? || api_key.strip.empty?
        # No API key configured
        return
      end

      success = send_with_retries(envelope, api_key)
      if success
        @consecutive_failures = 0
      else
        @consecutive_failures += 1
      end
    end

    def send_with_retries(envelope, api_key)
      uri = URI.parse(@ingest_url)
      payload = JSON.generate(envelope)

      (0..MAX_RETRIES).each do |attempt|
        begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 5
          http.read_timeout = 5

          req = Net::HTTP::Post.new(uri.request_uri)
          req["Content-Type"] = "application/json"
          req["x-api-key"] = api_key
          req.body = payload

          response = http.request(req)
          status_code = response.code.to_i

          if status_code >= 200 && status_code < 300
            return true
          elsif status_code == 429 || status_code >= 500
            # Transient error, retry with backoff
            if attempt < MAX_RETRIES
              sleep((2**attempt) * 0.25)
              next
            else
              $stderr.puts("[logcore] Failed to send logs after #{MAX_RETRIES + 1} attempts (HTTP #{status_code}): #{response.body}")
              return false
            end
          else
            # Permanent rejection (4xx except 429) - do not retry
            $stderr.puts("[logcore] Permanent rejection (HTTP #{status_code}): #{response.body}")
            return false
          end
        rescue StandardError => e
          # Network or SSL error - retry with backoff
          if attempt < MAX_RETRIES
            sleep((2**attempt) * 0.25)
            next
          else
            $stderr.puts("[logcore] Network error delivering logs after #{MAX_RETRIES + 1} attempts: #{e.message}")
            return false
          end
        end
      end

      false
    end
  end
end
