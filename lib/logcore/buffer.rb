# frozen_string_literal: true

require "monitor"

module Logcore
  class Buffer
    MAX_CAPACITY = 1000
    FLUSH_BATCH_SIZE = 20
    FLUSH_INTERVAL_SECONDS = 5.0

    def initialize(client = nil)
      @client = client || Logcore.client
      @queue = []
      @mutex = Mutex.new
      @cv = ConditionVariable.new
      @running = false
      @worker_thread = nil
      start_worker
    end

    def push(entry)
      return unless entry

      @mutex.synchronize do
        # Drop oldest entry if capacity exceeded
        @queue.shift if @queue.size >= MAX_CAPACITY
        @queue << entry

        # Signal worker if batch threshold reached
        @cv.signal if @queue.size >= FLUSH_BATCH_SIZE
      end
    end

    def size
      @mutex.synchronize { @queue.size }
    end

    def flush
      entries_to_send = []
      @mutex.synchronize do
        entries_to_send = @queue.dup
        @queue.clear
      end

      @client.send_batch(entries_to_send) unless entries_to_send.empty?
    end

    def shutdown
      @mutex.synchronize do
        @running = false
        @cv.broadcast
      end

      if @worker_thread && @worker_thread.alive?
        @worker_thread.join(5.0)
      end

      flush
    end

    private

    def start_worker
      @running = true
      @worker_thread = Thread.new do
        Thread.current.name = "logcore-worker" if Thread.current.respond_to?(:name=)

        while @running
          entries_to_send = []

          @mutex.synchronize do
            if @queue.size < FLUSH_BATCH_SIZE && @running
              @cv.wait(@mutex, FLUSH_INTERVAL_SECONDS)
            end

            entries_to_send = @queue.dup
            @queue.clear
          end

          if !entries_to_send.empty?
            begin
              @client.send_batch(entries_to_send)
            rescue StandardError => e
              $stderr.puts "[logcore] Background worker error: #{e.message}"
            end
          end
        end
      end
    end
  end
end
