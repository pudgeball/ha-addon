# frozen_string_literal: true

class Devices::TrmnlComponent < ViewComponent::Base
  include Devices::TemperatureDisplay

  def initialize(view_object:)
    @view_object = view_object
  end
end
