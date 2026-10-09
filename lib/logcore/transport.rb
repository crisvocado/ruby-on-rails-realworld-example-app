# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Logcore
  class Transport
    BUFFER_CAP = 1000
    BATCH_SIZE = 20
    MAX_BATCH_SIZE = 200
    FLUSH_INTERVAL = 5.0 # seconds
    CIRCUIT_BREAKER_THRESHOLD = 10

    class << self
      attr_accessor :capture_callback

      def instance
        @instance ||= new
      end

      def enqueue(entry)
        instance.enqueue(entry)
      end

      def flush
        instance.flush
      end

      def stop
        instance.stop
      end

      def reset!
        @instance&.stop
        @instance = nil
        @capture_callback = nil
      end
    end

    def initialize
      @queue = Thread::Queue.new
      @mutex = Mutex.new
      @consecutive_failures = 0
      @running = true
      @worker_thread = nil
      ensure_worker_started
    end

    def enqueue(entry)
      return unless entry

      @mutex.synchronize do
        # Enforce buffer cap: drop oldest entries when full
        while @queue.size >= BUFFER_CAP
          begin
            @queue.pop(true)
          rescue ThreadError
            break
          end
        end
        @queue.push(entry)
      end

      ensure_worker_started
    end

    def flush
      # Process all current items in queue
      entries = []
      @mutex.synchronize do
        until @queue.empty?
          begin
            entries << @queue.pop(true)
          rescue ThreadError
            break
          end
        end
      end

      return if entries.empty?

      entries.each_slice(MAX_BATCH_SIZE) do |batch|
        send_batch(batch)
      end
    end

    def stop
      @running = false
      if @worker_thread && @worker_thread.alive?
        @worker_thread.wakeup rescue nil
        @worker_thread.join(2.0) rescue nil
      end
    end

    private

    def ensure_worker_started
      return if @worker_thread && @worker_thread.alive?
      return unless @running

      @worker_thread = Thread.new do
        Thread.current.abort_on_exception = false
        Thread.current.name = "logcore-worker" if Thread.current.respond_to?(:name=)

        while @running
          begin
            batch = []
            deadline = Time.now + FLUSH_INTERVAL

            while batch.size < BATCH_SIZE && Time.now < deadline
              timeout = [deadline - Time.now, 0.1].max
              begin
                item = @queue.pop(false)
                batch << item if item
              rescue ThreadError
                # Queue empty
                sleep(0.1)
              end
            end

            send_batch(batch) unless batch.empty?
          rescue => e
            $stderr.puts "[Logcore] Worker thread exception: #{e.message}"
            sleep(1.0)
          end
        end
      end
    end

    def send_batch(batch)
      return if batch.empty?

      envelope = {
        "schema_version" => 1,
        "entries" => batch
      }

      if self.class.capture_callback
        begin
          self.class.capture_callback.call(envelope)
          @consecutive_failures = 0
          return true
        rescue => e
          $stderr.puts "[Logcore] Capture callback error: #{e.message}"
          return false
        end
      end

      config = Logcore.configuration
      return false unless config.enabled && config.key.present?

      if @consecutive_failures >= CIRCUIT_BREAKER_THRESHOLD
        # Circuit breaker tripped: drop queue and return
        @mutex.synchronize do
          @queue.clear
        end
        $stderr.puts "[Logcore] Circuit breaker active (#{CIRCUIT_BREAKER_THRESHOLD} failures); dropping logs."
        return false
      end

      payload = JSON.generate(envelope)
      uri = URI.join(config.url.end_with?("/") ? config.url : "#{config.url}/", "v1/logs")

      4.times do |attempt|
        begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 5
          http.read_timeout = 10

          req = Net::HTTP::Post.new(uri.request_uri)
          req["Content-Type"] = "application/json"
          req["x-api-key"] = config.key
          req.body = payload

          res = http.request(req)
          status = res.code.to_i

          if status >= 200 && status < 300
            @consecutive_failures = 0
            return true
          elsif status == 429 || status >= 500
            if attempt < 3
              sleep((2**attempt) * 0.25)
              next
            else
              @consecutive_failures += 1
              $stderr.puts "[Logcore] Transient delivery error (#{status}): #{res.body}"
              return false
            end
          elsif status >= 400 && status < 500
            # Permanent 4xx error (invalid format / rejected) - do not retry
            @consecutive_failures += 1
            $stderr.puts "[Logcore] Permanent delivery rejection (#{status}): #{res.body}"
            return false
          end
        rescue => e
          if attempt < 3
            sleep((2**attempt) * 0.25)
            next
          else
            @consecutive_failures += 1
            $stderr.puts "[Logcore] Network delivery failure: #{e.message}"
            return false
          end
        end
      end

      false
    end
  end
end
