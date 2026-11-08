# frozen_string_literal: true

class DeviceBroadcaster
  # Track last known data hash per device to avoid redundant broadcasts
  @last_hashes = {}
  @mutex = Mutex.new

  class << self
    def broadcast_if_changed(device)
      data = view_object_for(device)
      # Exclude the raw current_time value from the dedup hash: the Mira renders
      # its clock client-side, so a new minute alone must not trigger a refresh
      # broadcast (which would cause a full-body swap / e-ink blink every minute).
      data_hash = Digest::MD5.hexdigest(data.except(:current_time).to_json)

      should_broadcast = @mutex.synchronize do
        if @last_hashes[device.id] != data_hash
          @last_hashes[device.id] = data_hash
          true
        else
          false
        end
      end

      if should_broadcast
        DeviceChannel.broadcast_to(device, {action: "refresh", deploy_time: DEPLOY_TIME})
        Rails.logger.info "[DeviceBroadcaster] Content pushed to #{device.name}"
      end
    end

    # How long a "no realtime (Mira) devices" answer is trusted before asking
    # the database again, so installs without any skip the per-tick query.
    REALTIME_CHECK_SECONDS = 60

    def broadcast_all_mira_devices
      return unless realtime_devices_present?

      Device.where(model: Device::REALTIME_MODELS).find_each do |device|
        broadcast_if_changed(device)
      rescue => e
        Rails.logger.error "[DeviceBroadcaster] Failed for #{device.name}: #{e.message}"
      end
    end

    def realtime_devices_present?
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @mutex.synchronize do
        return true if @realtime_present
        return false if @realtime_checked_at && now - @realtime_checked_at < REALTIME_CHECK_SECONDS
      end

      present = Device.where(model: Device::REALTIME_MODELS).exists?
      @mutex.synchronize do
        @realtime_present = present
        @realtime_checked_at = now
      end
      present
    end

    def clear_hash(device_id)
      @mutex.synchronize do
        if device_id == :all
          @realtime_present = nil
          @realtime_checked_at = nil
          @last_hashes.clear
        else
          @last_hashes.delete(device_id)
        end
      end
    end

    private

    # Override in host apps for app-specific display data
    def view_object_for(device)
      if device.demo_mode_enabled?
        DemoDeviceContent.new.call
      else
        DeviceContent.new.call
      end
    end
  end
end
