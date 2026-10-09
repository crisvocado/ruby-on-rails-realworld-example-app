# frozen_string_literal: true

require_relative "../../lib/logcore"

# Attach Logcore transport adapter to Rails.logger
if defined?(Rails.logger) && Rails.logger
  Logcore.attach_logger(Rails.logger)
end

Rails.application.config.after_initialize do
  Logcore.attach_logger(Rails.logger) if defined?(Rails.logger) && Rails.logger
end
