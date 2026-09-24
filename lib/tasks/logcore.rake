# frozen_string_literal: true

require "json"

namespace :logcore do
  desc "Emit a test ERROR log to Logcore"
  task probe: :environment do
    if defined?(Logcore) && Logcore.transport
      Logcore.transport.define_singleton_method(:send_batch) do |batch|
        batch.each do |entry|
          puts JSON.generate(entry.to_h)
        end
        record_success
      end
    end
    Rails.logger.error("Logcore test probe error")
    Logcore.flush if defined?(Logcore)
  end
end
