# frozen_string_literal: true

class Devices::ReterminalComponent < ViewComponent::Base
  include Devices::TemperatureDisplay

  def initialize(view_object:)
    @view_object = view_object
  end
end
