# frozen_string_literal: true

require "json"

captured_entry = nil
Logcore::Client.stub_sender = ->(envelope) {
  captured_entry = envelope["entries"] ? envelope["entries"].first : nil
}

begin
  raise StandardError, "Logcore integration probe error"
rescue => e
  Rails.logger.error(e)
end

Logcore.flush

if captured_entry
  puts JSON.generate(captured_entry)
end

