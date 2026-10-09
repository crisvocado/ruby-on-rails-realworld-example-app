#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"

captured_payload = nil
Logcore::Transport.capture_callback = lambda do |envelope|
  captured_payload = envelope
end

# Trigger an ERROR through the project's existing logger
Rails.logger.error("Logcore test error")

# Flush and drain queued delivery
Logcore::Transport.flush
Logcore::Transport.stop

if captured_payload
  puts JSON.generate(captured_payload)
  exit 0
else
  warn "[Logcore Probe] No payload captured"
  exit 1
end
