# frozen_string_literal: true

require_relative "../../config/environment" unless defined?(Rails.application)

# Stub transport at send boundary so probe outputs emitted JSON entry to stdout
if defined?(Logcore) && Logcore.transport
  Logcore.transport.define_singleton_method(:send_batch) do |entries|
    entries&.each do |entry|
      puts JSON.generate(entry)
    end
    true
  end
end

Rails.logger.error("Logcore probe test error")
Logcore.flush(timeout: 3.0) if defined?(Logcore)
