# frozen_string_literal: true

require_relative "../../lib/logcore"

Logcore.attach_to_rails_logger!
Rails.application.config.middleware.use Logcore::Middleware
