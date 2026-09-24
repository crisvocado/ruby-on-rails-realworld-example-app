# frozen_string_literal: true

require "active_support/current_attributes"

module Logcore
  class Current < ActiveSupport::CurrentAttributes
    attribute :trace
    attribute :context
    attribute :labels
  end
end
