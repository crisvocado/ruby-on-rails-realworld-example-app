# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"

module Logcore
  class Client
    MAX_ENTRIES_PER_REQUEST = 200
    MAX_RETRIES = 3
    CIRCUIT_BREAKER_THRESHOLD = 10

    TRANSIENT_NETWORK_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::ETIMEDOUT,
      Errno::EHOSTUNREACH,
      Net::OpenTimeout,
      Net::ReadTimeout,
      SocketError,
      OpenSSL::SSL::SSLError,
      IOError,
      SystemCallError
    ].freeze

    class TransientDeliveryError < StandardError
      attr_reader :status, :body

      def initialize(status, body = nil)
        @status = status
        @body = body
        super("HTTP #{status}: #{body}")
      end
    end

    class << self
      attr_accessor :stub_sender, :last_sent_envelope
    end

    attr_reader :consecutive_failures

    def initialize(configuration = nil)
      @config = configuration || Logcore.configuration
      @consecutive_failures = 0
      @mutex = Mutex.new
    end

    def send_batch(entries)
      return if entries.nil? || entries.empty?

      # Check circuit breaker
      @mutex.synchronize do
        if @consecutive_failures >= CIRCUIT_BREAKER_THRESHOLD
          $stderr.puts "[logcore] Circuit breaker active (consecutive failures: #{@consecutive_failures}). Dropping #{entries.size} entries."
          return false
        end
      end

      # Send in chunks of at most MAX_ENTRIES_PER_REQUEST
      entries.each_slice(MAX_ENTRIES_PER_REQUEST) do |chunk|
        send_chunk(chunk)
      end
    end

    def send_chunk(chunk)
      envelope = {
        "schema_version" => 1,
        "entries" => chunk
      }

      self.class.last_sent_envelope = envelope

      if self.class.stub_sender
        self.class.stub_sender.call(envelope)
        record_success
        return true
      end

      endpoint_url = @config.url
      return false if endpoint_url.to_s.empty?

      logs_url = endpoint_url.end_with?("/v1/logs") ? endpoint_url : "#{endpoint_url.chomp('/')}/v1/logs"
      uri = URI.parse(logs_url)

      json_body = JSON.generate(envelope)
      headers = {
        "Content-Type" => "application/json"
      }
      headers["x-api-key"] = @config.key if @config.key && !@config.key.empty?

      attempt = 0
      begin
        # Set self-exclusion flag on current thread
        Thread.current[:logcore_sending] = true

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Post.new(uri.request_uri, headers)
        request.body = json_body

        response = http.request(request)
        status = response.code.to_i

        if status >= 200 && status < 300
          record_success
          true
        elsif status == 429 || (status >= 500 && status < 600)
          raise TransientDeliveryError.new(status, response.body)
        elsif status >= 400 && status < 500
          # Permanent client error (4xx except 429) -> DO NOT RETRY, echo server reason
          $stderr.puts "[logcore] Permanent rejection (HTTP #{status}): #{response.body}"
          false
        else
          record_failure
          $stderr.puts "[logcore] Unexpected HTTP status: #{status} #{response.body}"
          false
        end
      rescue TransientDeliveryError => e
        if attempt < MAX_RETRIES
          attempt += 1
          sleep_duration = (2**attempt) * 0.25
          sleep(sleep_duration)
          retry
        else
          record_failure
          $stderr.puts "[logcore] Exhausted #{MAX_RETRIES} retries after server error (HTTP #{e.status}): #{e.body}"
          false
        end
      rescue *TRANSIENT_NETWORK_ERRORS => e
        if attempt < MAX_RETRIES
          attempt += 1
          sleep_duration = (2**attempt) * 0.25
          sleep(sleep_duration)
          retry
        else
          record_failure
          $stderr.puts "[logcore] Network error after #{MAX_RETRIES} retries: #{e.message}"
          false
        end
      rescue StandardError => e
        record_failure
        $stderr.puts "[logcore] Unexpected error during log delivery: #{e.message}"
        false
      ensure
        Thread.current[:logcore_sending] = false
      end
    end

    private

    def record_success
      @mutex.synchronize do
        @consecutive_failures = 0
      end
    end

    def record_failure
      @mutex.synchronize do
        @consecutive_failures += 1
        if @consecutive_failures >= CIRCUIT_BREAKER_THRESHOLD
          $stderr.puts "[logcore] Circuit breaker tripped after #{CIRCUIT_BREAKER_THRESHOLD} consecutive failures. Stopping transmission."
        end
      end
    end
  end
end
