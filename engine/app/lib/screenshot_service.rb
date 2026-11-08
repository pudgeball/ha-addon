# frozen_string_literal: true

# :nocov:
class ScreenshotService
  VIEWPORT_WIDTH = 480
  VIEWPORT_HEIGHT = 800

  # Ferrum's per-command timeout and browser-launch timeout (seconds).
  COMMAND_TIMEOUT = 15
  PROCESS_TIMEOUT = 20

  # Hard wall-clock ceiling for a single capture. If a capture exceeds this we
  # force-kill the browser process - the only reliable way to unblock a thread
  # parked in a corrupted/deadlocked CDP websocket read - so a job can never
  # wedge indefinitely the way RefreshDeviceScreenshotJob did in production.
  CAPTURE_DEADLINE = 20

  # The shared browser is not thread-safe and is driven over a single CDP
  # websocket. Concurrent GoodJob threads interleaving commands corrupt the
  # protocol stream and deadlock both threads. Serialize all access.
  MUTEX = Mutex.new

  class << self
    # Seconds to keep the browser open after a capture so the next one can
    # reuse it instead of launching Chromium again. 0 (the default) quits right
    # after every capture, for hosts with tight memory limits. The Home
    # Assistant add-on sets a short window, so the main and Year captures of a
    # refresh, or a few Regenerate clicks in a row, share one browser.
    attr_accessor :keep_browser_for

    def capture(url, width: VIEWPORT_WIDTH, height: VIEWPORT_HEIGHT, grayscale_depth: 2, rotate: true, raw: false, dither: true, grayscale_only: false)
      MUTEX.synchronize do
        started_at = monotonic_now
        failed = true
        # Any capture cancels a pending idle quit from an earlier one.
        @idle_generation = (@idle_generation || 0) + 1
        @timings = {}
        png_base64 = capture_with_deadline(url, width: width, height: height)

        process_started_at = monotonic_now
        result = process_capture(png_base64, raw: raw, grayscale_only: grayscale_only, rotate: rotate, grayscale_depth: grayscale_depth, dither: dither)
        @timings[:process_ms] = elapsed_ms(process_started_at)
        failed = false
        result
      ensure
        # A failed capture always quits the browser, so a broken one is never reused.
        if failed || keep_browser_for.to_f <= 0
          quit_started_at = monotonic_now
          reset!
          @timings[:quit_ms] = elapsed_ms(quit_started_at) if @timings
        else
          schedule_idle_quit
        end
        log_timings(url, started_at, failed: failed)
      end
    end

    def browser
      @browser ||= Ferrum::Browser.new(
        headless: "new",
        browser_path: find_browser_path,
        env: {
          "LD_PRELOAD" => nil,
          "MALLOC_CONF" => nil
        },
        window_size: [VIEWPORT_WIDTH, VIEWPORT_HEIGHT],
        timeout: COMMAND_TIMEOUT,
        process_timeout: PROCESS_TIMEOUT,
        pending_connection_errors: false,
        browser_options: {
          "no-sandbox" => nil,
          "disable-gpu" => nil,
          "disable-dev-shm-usage" => nil,
          "disable-software-rasterizer" => nil,
          "renderer-process-limit" => "1",
          "font-render-hinting" => "none",
          "disable-font-subpixel-positioning" => nil
        }
      )
    end

    def reset!
      @browser&.quit
      @browser = nil
    end

    private

    def process_capture(png_base64, raw:, grayscale_only:, rotate:, grayscale_depth:, dither:)
      if raw
        png_base64
      elsif grayscale_only
        image = MiniMagick::Image.read(Base64.decode64(png_base64), ".png")
        image.rotate "90" if rotate
        image.combine_options do |c|
          c.colorspace "Gray"
          c.dither("None")
          c.colors 16
          c.depth 4
        end
        image.format "png"
        Base64.strict_encode64(image.to_blob)
      else
        process_image(Base64.decode64(png_base64), grayscale_depth: grayscale_depth, rotate: rotate, dither: dither)
      end
    end

    # Quits the browser once it has sat unused for keep_browser_for seconds.
    # A capture in the meantime bumps the generation, which cancels this quit.
    def schedule_idle_quit
      generation = @idle_generation
      delay = keep_browser_for.to_f
      Thread.new do
        sleep delay
        MUTEX.synchronize { reset! if @idle_generation == generation }
      end
    end

    # One line per capture with where the time went: launching Chromium (only
    # when no browser was open), loading the page, taking the screenshot, and
    # converting it for the display.
    def log_timings(url, started_at, failed:)
      timings = (@timings || {}).merge(total_ms: elapsed_ms(started_at))
      fields = timings.map { |key, value| "#{key}=#{value}" }.join(" ")
      path = url.to_s.sub(%r{\Ahttps?://[^/]+}, "").sub(/key=[^&]+/, "key=…")
      Rails.logger.info("[ScreenshotService] #{failed ? "failed" : "captured"} #{fields} url=#{path}")
    rescue => e
      Rails.logger.warn("[ScreenshotService] timing log failed: #{e.message}")
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_now - started_at) * 1000).round
    end

    # Runs the capture on a worker thread and enforces a hard wall-clock
    # deadline. If the deadline passes, force-kill the browser (which unblocks
    # the worker's stuck syscall), abandon the worker, and raise so the job
    # fails fast instead of sitting in Running forever.
    def capture_with_deadline(url, width:, height:, deadline: CAPTURE_DEADLINE)
      worker = Thread.new do
        Thread.current.report_on_exception = false
        capture_screenshot_with_retry(url, width: width, height: height)
      end

      if worker.join(deadline).nil?
        Rails.logger.error "[ScreenshotService] Capture exceeded #{deadline}s; killing browser"
        reset!
        worker.kill
        worker.join(5)
        raise Timeout::Error, "screenshot capture exceeded #{deadline}s"
      end

      worker.value
    end

    def capture_screenshot_with_retry(url, width:, height:)
      capture_screenshot(url, width: width, height: height)
    rescue Ferrum::DeadBrowserError, Ferrum::NoSuchPageError => e
      Rails.logger.warn "[ScreenshotService] Browser dead, resetting and retrying: #{e.message}"
      reset!
      capture_screenshot(url, width: width, height: height)
    end

    def capture_screenshot(url, width:, height:)
      timings = (@timings ||= {})
      step_started_at = monotonic_now
      timings[:browser] = @browser ? "reused" : "launched"
      page = browser.create_page
      timings[:launch_ms] = elapsed_ms(step_started_at)
      begin
        page.command("Emulation.setDeviceMetricsOverride",
          width: width,
          height: height,
          deviceScaleFactor: 1,
          mobile: false)
        step_started_at = monotonic_now
        page.go_to(url)
        timings[:load_ms] = elapsed_ms(step_started_at)
        step_started_at = monotonic_now
        png_base64 = page.screenshot(format: "png")
        timings[:screenshot_ms] = elapsed_ms(step_started_at)
      ensure
        begin
          page&.close
        rescue Ferrum::Error
          # Page or browser already gone; nothing to clean up.
        end
      end
      png_base64
    end

    def process_image(png_data, grayscale_depth: 2, rotate: true, dither: true)
      image = MiniMagick::Image.read(png_data, ".png")
      image.rotate "90" if rotate
      image.combine_options do |c|
        c.colorspace "Gray"
        c.dither("None") unless dither
        c.dither("FloydSteinberg") if dither
        c.posterize(2**grayscale_depth)
        c.depth grayscale_depth
      end
      image.format "png"
      Base64.strict_encode64(image.to_blob)
    end

    def find_browser_path
      ENV["BROWSER_PATH"].presence ||
        ENV["GOOGLE_CHROME_BIN"].presence ||
        ENV["CHROME_BIN"].presence ||
        [
          "/usr/bin/chromium",
          "/usr/bin/chromium-browser",
          "/usr/bin/google-chrome",
          "/usr/bin/google-chrome-stable",
          "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        ].find { |path| File.exist?(path) }
    end
  end
end
# :nocov:
