# frozen_string_literal: true

# Shows temperatures in the account's unit and, when the device's
# "show_secondary_temperature" option is on, follows each reading with the same
# reading in the other unit, smaller and gray: "72°" becomes "72° 22°" and
# "72° / 50°" becomes "72° 22° / 50° 10°". Included by the device components.
module Devices::TemperatureDisplay
  READING = /(-?\d+)°/
  SECONDARY_STYLE = "font-size: .72em; color: #444; margin-left: .15em; font-weight: inherit;"

  # A temperature string ("72°", "72° / 50°"), returned ready to render.
  def temperature(text)
    return text if text.blank? || !secondary_temperature?

    ERB::Util.html_escape(text).to_str.gsub(READING) do
      reading = Regexp.last_match(1).to_i
      %(#{reading}°<span style="#{SECONDARY_STYLE}">#{convert_temperature(reading)}°</span>)
    end.html_safe
  end

  # An event's summary, with temperatures shown as #temperature does when the
  # event is a weather forecast. Other titles are left alone, so "Bake at 350°"
  # isn't converted.
  def event_summary(event)
    event[:weather] ? temperature(event[:summary]) : event[:summary]
  end

  private

  def secondary_temperature?
    @view_object.dig(:configuration, "show_secondary_temperature") == "true"
  end

  def convert_temperature(reading)
    if @view_object[:temperature_unit] == "C"
      (reading * 9.0 / 5 + 32).round
    else
      ((reading - 32) * 5.0 / 9).round
    end
  end
end
