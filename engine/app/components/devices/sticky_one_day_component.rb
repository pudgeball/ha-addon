# frozen_string_literal: true

class Devices::StickyOneDayComponent < ViewComponent::Base
  include Devices::TemperatureDisplay

  def initialize(view_object:)
    @view_object = view_object
  end
end
