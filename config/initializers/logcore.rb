# frozen_string_literal: true

require_relative "../../lib/logcore"

# Register Logcore middleware for trace propagation and error handling
Rails.application.config.middleware.use(Logcore::Middleware)

# Attach Logcore transport adapter to Rails.logger after initialization
Rails.application.config.after_initialize do
  Logcore.setup(Rails.application)
end
