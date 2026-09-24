# frozen_string_literal: true

require "net/http"

module Logcore
  module HttpPatch
    def self.install!
      return if @installed

      Net::HTTP.prepend(NetHttpExtension)
      @installed = true
    end

    module NetHttpExtension
      def request(req, *args, &block)
        begin
          if !Thread.current[:logcore_internal_request] && Logcore::Current.trace
            trace = Logcore::Current.trace
            ingest_uri = Logcore.configuration.ingest_uri

            # Self-exclusion: Do not instrument calls to logcore ingest URL
            is_logcore = (address == ingest_uri.host && port == ingest_uri.port)

            if !is_logcore && trace && !req.key?("traceparent")
              sampled_hex = trace["sampled"] ? "01" : "00"
              traceparent = "00-#{trace['traceId']}-#{trace['spanId']}-#{sampled_hex}"
              req["traceparent"] = traceparent
            end
          end
        rescue => e
          # Header injection failure should never block outgoing HTTP request
        end

        super
      end
    end
  end
end
