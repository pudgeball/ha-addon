# frozen_string_literal: true

# The add-on takes device screenshots with a headless browser running in the
# same container, so it always loads the display page from Puma directly rather
# than from whatever address the person used to open Timeframe (Home Assistant's
# ingress proxy, the host's LAN IP, a hostname...), which the browser inside the
# add-on can't always reach. 127.0.0.1 rather than localhost, which can resolve
# to the IPv6 address Puma doesn't listen on.
Rails.application.config.to_prepare do
  Device.screenshot_host = "http://127.0.0.1:#{ENV.fetch("PORT", 3000)}"
  # Starting Chromium takes a couple of seconds, so keep it open for a while
  # after a capture: a refresh captures the main and Year pages back to back,
  # and Regenerate clicks tend to come in bursts. It still quits when idle so
  # it isn't holding memory between the 15-minute refreshes.
  ScreenshotService.keep_browser_for = ENV.fetch("SCREENSHOT_KEEP_BROWSER_SECONDS", 120).to_f
end
