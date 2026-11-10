# frozen_string_literal: true

# Records a per-minute uptime heartbeat. The mere existence of the row marks the
# app as "up" for that minute; the healthy flag reflects whether every Home
# Assistant domain check is passing. config/scheduler.rb calls record! every
# minute directly rather than through the job queue, which would log four
# lines a minute for it.
class RecordUptimeJob < ActiveJob::Base
  def perform
    self.class.record!
  end

  def self.record!
    healthy =
      begin
        api = HomeAssistantApi.new
        DashboardController::HA_DOMAIN_CHECKS.all? { |check| api.send(check[:healthy]) }
      rescue
        false
      end

    UptimeCheck.record!(healthy: healthy)
  end
end
