# frozen_string_literal: true

require "test_helper"

class TemperatureDisplayTest < ActiveSupport::TestCase
  class Host
    include Devices::TemperatureDisplay

    def initialize(view_object)
      @view_object = view_object
    end
  end

  def host(unit: "F", on: true)
    Host.new(temperature_unit: unit, configuration: {"show_secondary_temperature" => on ? "true" : "false"})
  end

  def secondary(reading)
    %(<span style="#{Devices::TemperatureDisplay::SECONDARY_STYLE}">#{reading}°</span>)
  end

  test "leaves temperatures alone when the option is off" do
    assert_equal "72°", host(on: false).temperature("72°")
    assert_equal "72°", Host.new(configuration: {}).temperature("72°")
  end

  test "leaves blank temperatures alone" do
    assert_nil host.temperature(nil)
    assert_equal "", host.temperature("")
  end

  test "adds Celsius after a Fahrenheit reading" do
    html = host.temperature("72°")
    assert_equal "72°#{secondary(22)}", html
    assert_predicate html, :html_safe?
  end

  test "adds Celsius to each reading in a high and low" do
    assert_equal "72°#{secondary(22)} / 50°#{secondary(10)}", host.temperature("72° / 50°")
  end

  test "adds Fahrenheit after a Celsius reading" do
    assert_equal "22°#{secondary(72)}", host(unit: "C").temperature("22°")
  end

  test "converts readings below zero" do
    assert_equal "-4°#{secondary(-20)}", host.temperature("-4°")
    assert_equal "-5°#{secondary(23)}", host(unit: "C").temperature("-5°")
  end

  test "escapes the rest of the text" do
    assert_equal "&lt;b&gt; 72°#{secondary(22)}", host.temperature("<b> 72°")
  end

  test "converts weather event summaries only" do
    assert_equal "58°#{secondary(14)}", host.event_summary({weather: true, summary: "58°"})
    assert_equal "Bake at 350°", host.event_summary({weather: false, summary: "Bake at 350°"})
  end

  test "the timeline shows both units for forecasts when the option is on" do
    html = render_trmnl(configuration: {"show_secondary_temperature" => "true"})
    assert_includes html, "72°#{secondary(22)}"
    assert_includes html, "58°#{secondary(14)}"
    assert_includes html, "Bake at 350°"
    refute_includes html, "350°<span"
  end

  test "the timeline shows one unit by default" do
    html = render_trmnl(configuration: {})
    assert_includes html, "72°"
    refute_includes html, Devices::TemperatureDisplay::SECONDARY_STYLE
  end

  private

  def render_trmnl(configuration:)
    date = Date.new(2026, 8, 19)
    view_object = {
      top_left: [],
      top_right: [],
      weather_status: [],
      battery: nil,
      current_time: Time.zone.local(2026, 8, 19, 8, 0, 0),
      current_temperature: "72°",
      temperature_unit: "F",
      configuration: configuration,
      day_groups: [{
        day_name: "Today",
        date: date,
        show_daily: true,
        daily: [],
        periodic: [
          DeviceEvent.new(id: "_ha_weather_hour_1", starts_at: Time.zone.local(2026, 8, 19, 8), ends_at: Time.zone.local(2026, 8, 19, 8),
            summary: "58°", icon: "weather-sunny", timezone: "UTC"),
          DeviceEvent.new(starts_at: Time.zone.local(2026, 8, 19, 9), ends_at: Time.zone.local(2026, 8, 19, 10),
            summary: "Bake at 350°", icon: "calendar", timezone: "UTC")
        ].map { |event| event.as_json(date: date) }
      }]
    }
    ApplicationController.render(Devices::TrmnlComponent.new(view_object: view_object), layout: false)
  end
end
