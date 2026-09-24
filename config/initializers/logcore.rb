# frozen_string_literal: true

require_relative "../../lib/logcore"

# Initialize Logcore and register logger adapter
Logcore.setup

# Register Rack middleware for traceparent propagation and error capture
Rails.application.config.middleware.use Logcore::Middleware
