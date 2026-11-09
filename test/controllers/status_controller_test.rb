# frozen_string_literal: true

require "test_helper"

class StatusControllerTest < ActionDispatch::IntegrationTest
  test "status page shows api statuses" do
    get "/status"
    assert_response :success
    assert_includes response.body, "API Status"
    assert_includes response.body, "States"
    assert_includes response.body, "Calendars"
    assert_includes response.body, "Config"
    assert_includes response.body, "Weather"
  end

  test "status page summarizes the year view calendars" do
    store = ActiveSupport::Cache::MemoryStore.new
    api = HomeAssistantApi.new(TimeframeConfig.new, store: store)
    api.seed_config(DEFAULT_TEST_CONFIG)
    api.send(:save_domain, HomeAssistantApi::YEAR_CALENDAR_DOMAIN, [
      {id: "trip", starts_at: "2027-06-01", ends_at: "2027-06-04", summary: "Trip", entity_id: "calendar.family"}
    ])

    Rails.stub(:cache, store) do
      get "/status/sections/year_calendars"
    end

    assert_response :success
    assert_includes response.body, "1 event in the next 12 months"
    assert_includes response.body, "calendar.family"
    assert_includes response.body, "Jun 1, 2027"
  end

  test "status page loads its long detail sections on demand" do
    get "/status"

    assert_response :success
    StatusController::SECTIONS.each do |section, title|
      assert_includes response.body, %(data-status-section="/status/sections/#{section}")
      assert_includes response.body, title
    end
    refute_includes response.body, "No calendar events."
  end

  test "each status detail section renders on its own" do
    {"calendar_events" => /\d+ events?</, "hourly_forecast" => /\d+ hours?</, "daily_forecast" => /\d+ days?</}.each do |section, count_line|
      get "/status/sections/#{section}"
      assert_response :success
      assert_match count_line, response.body
      refute_includes response.body, "<html", "a section is a fragment, not a page"
    end
  end

  test "unknown status sections are not found" do
    get "/status/sections/nope"
    assert_response :not_found
  end

  test "status page shows the uptime section" do
    UptimeCheck.delete_all
    get "/status"
    assert_response :success
    assert_includes response.body, "Uptime"
    assert_includes response.body, "Past 90 days"
  end
end
