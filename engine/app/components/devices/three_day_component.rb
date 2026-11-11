# frozen_string_literal: true

class Devices::ThreeDayComponent < ViewComponent::Base
  include Devices::TemperatureDisplay

  include ActionView::Helpers::TextHelper

  def initialize(view_object:)
    @view_object = view_object
  end
end
