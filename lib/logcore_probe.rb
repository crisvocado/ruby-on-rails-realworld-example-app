# frozen_string_literal: true

require "json"

# In probe/validation mode, intercept the transport send to print the JSON log entry to stdout
if defined?(Logcore) && Logcore.transport
  Logcore.transport.define_singleton_method(:send_batch) do |batch|
    batch.each do |entry|
      puts JSON.generate(entry.to_h)
    end
    record_success
  end
end

# Emit a test ERROR log to Logcore via Rails.logger
Rails.logger.error("Logcore test probe error")
Logcore.flush if defined?(Logcore)
