scheduler = Rufus::Scheduler.new

# Each task logs how long it took (see TaskTimer). The every-2-seconds ones are
# summed up once a minute instead of logged on every run.
timers = Hash.new do |hash, name|
  hash[name] = name.start_with?("2s ") ? TaskTimer.new(name, summary_every: 60, slow_ms: 1000) : TaskTimer.new(name)
end

api = HomeAssistantApi.new
api.fetch_config

# Fetch states every 2 seconds for near-real-time updates
scheduler.every "2s" do
  timers["2s fetch_states"].run { HomeAssistantApi.new.fetch_states }
  timers["2s broadcast_mira"].run { DeviceBroadcaster.broadcast_all_mira_devices }
end

# Fetch calendars and weather on startup
scheduler.in "5s" do
  api = HomeAssistantApi.new
  timers["startup fetch_calendars"].run { api.fetch_calendars }
  timers["startup fetch_year_calendars"].run { api.fetch_year_calendars }
  timers["startup fetch_weather"].run { api.fetch_weather }
  timers["startup calendar_import"].run { HomeAssistantCalendarImport.new(account: Account.first).call if Account.first }
  timers["startup broadcast_mira"].run { DeviceBroadcaster.broadcast_all_mira_devices }
end

scheduler.every "5m" do
  timers["5m fetch_config"].run { HomeAssistantApi.new.fetch_config }
  timers["5m broadcast_mira"].run { DeviceBroadcaster.broadcast_all_mira_devices }
end

scheduler.every "1m" do
  timers["1m fetch_calendars"].run { HomeAssistantApi.new.fetch_calendars }
  timers["1m calendar_import"].run { HomeAssistantCalendarImport.new(account: Account.first).call if Account.first }
  timers["1m broadcast_mira (calendars)"].run { DeviceBroadcaster.broadcast_all_mira_devices }
end

# The Year template's calendars cover the next 12 months, so they're fetched
# less often than the short-range ones, but often enough that a newly added
# trip shows up within a refresh or two.
scheduler.every "15m" do
  timers["15m fetch_year_calendars"].run { HomeAssistantApi.new.fetch_year_calendars }
end

scheduler.every "1m" do
  timers["1m fetch_weather"].run { HomeAssistantApi.new.fetch_weather }
  timers["1m broadcast_mira (weather)"].run { DeviceBroadcaster.broadcast_all_mira_devices }
end

scheduler.join
