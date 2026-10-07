# frozen_string_literal: true

require_relative "../logcore"

captured = []
Logcore.stub_transport! do |envelope|
  captured << envelope
end

# Trigger an ERROR through Rails existing logger
begin
  raise StandardError, "Logcore integration probe error"
rescue => e
  Rails.logger.error(e)
end

# Drain queued asynchronous delivery
Logcore.flush(timeout: 5.0)

if captured.empty?
  $stderr.puts("[logcore probe] No envelope captured")
  exit 1
end

# Output the real captured HTTP request envelope unchanged
puts JSON.generate(captured.first)
