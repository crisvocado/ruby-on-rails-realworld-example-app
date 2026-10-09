# frozen_string_literal: true

require "rails/railtie"

module Logcore
  class Railtie < Rails::Railtie
    initializer "logcore.middleware" do |app|
      app.middleware.use Logcore::Middleware
    end

    config.after_initialize do
      Logcore.attach_logger(Rails.logger) if defined?(Rails.logger) && Rails.logger
    end
  end
end
