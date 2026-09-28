# frozen_string_literal: true

require_relative "../../lib/logcore"

# Initialize Logcore integration with Rails.logger and Rack middleware
Logcore.setup(Rails.application)
