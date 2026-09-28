# frozen_string_literal: true

require "json"

Logcore.stub_transport! do |batch|
  batch.each do |entry|
    puts JSON.generate(entry.to_h)
  end
end

Rails.logger.error("Logcore probe test error")
Logcore.flush(timeout: 5) if defined?(Logcore)
