# frozen_string_literal: true

require "test_helper"

class ScreenshotServiceTest < Minitest::Test
  def setup
    @keep_browser_for = ScreenshotService.keep_browser_for
  end

  def teardown
    ScreenshotService.instance_variable_set(:@browser, nil)
    ScreenshotService.keep_browser_for = @keep_browser_for
  end

  FakePage = Struct.new(:visited) do
    def command(*, **) = nil
    def go_to(url) = (self.visited = url)
    def screenshot(**) = "cG5n"
    def close = nil
  end

  FakeBrowser = Struct.new(:pages, :quit_count) do
    def create_page = FakePage.new.tap { |page| pages << page }
    def quit = (self.quit_count += 1)
  end

  def fake_browser
    FakeBrowser.new([], 0)
  end

  def test_capture_quits_the_browser_straight_away_by_default
    ScreenshotService.keep_browser_for = 0
    browser = fake_browser
    ScreenshotService.instance_variable_set(:@browser, browser)

    ScreenshotService.capture("http://example.test/d/1?key=secret", raw: true)

    assert_equal 1, browser.quit_count
    assert_nil ScreenshotService.instance_variable_get(:@browser)
  end

  def test_capture_keeps_the_browser_for_the_next_capture_then_quits_when_idle
    ScreenshotService.keep_browser_for = 0.3
    browser = fake_browser
    ScreenshotService.instance_variable_set(:@browser, browser)

    ScreenshotService.capture("http://example.test/d/1", raw: true)
    sleep 0.15
    ScreenshotService.capture("http://example.test/d/1?page=1", raw: true)
    sleep 0.2

    assert_equal 1, browser.pages.size, "both captures should use the same browser tab"
    assert_equal "http://example.test/d/1?page=1", browser.pages.first.visited
    assert_equal 0, browser.quit_count, "the second capture should cancel the first one's idle quit"

    sleep 0.3
    assert_equal 1, browser.quit_count
    assert_nil ScreenshotService.instance_variable_get(:@browser)
  end

  def test_failed_capture_quits_the_browser_even_when_keeping_it
    ScreenshotService.keep_browser_for = 60
    reset_called = false

    ScreenshotService.stub(:capture_screenshot_with_retry, ->(*, **) { raise "boom" }) do
      ScreenshotService.stub(:reset!, -> { reset_called = true }) do
        assert_raises(RuntimeError) { ScreenshotService.capture("http://example.test", raw: true) }
      end
    end

    assert reset_called
  end

  def test_capture_logs_where_the_time_went_without_the_display_key
    ScreenshotService.keep_browser_for = 0
    ScreenshotService.instance_variable_set(:@browser, fake_browser)
    log = StringIO.new

    Rails.stub(:logger, ActiveSupport::Logger.new(log)) do
      ScreenshotService.capture("http://127.0.0.1:8099/d/1?key=secret&page=1&generation=true", raw: true)
    end

    line = log.string.lines.grep(/\[ScreenshotService\]/).first
    assert_match(/captured browser=reused launch_ms=\d+ load_ms=\d+ screenshot_ms=\d+ process_ms=\d+ quit_ms=\d+ total_ms=\d+/, line)
    assert_includes line, "url=/d/1?key=…&page=1&generation=true"
    refute_includes line, "secret"
  end

  def test_browser_does_not_preload_jemalloc
    browser = Object.new

    Ferrum::Browser.stub(:new, ->(**options) {
      assert_nil options.dig(:env, "LD_PRELOAD")
      assert_nil options.dig(:env, "MALLOC_CONF")
      assert_equal "1", options.dig(:browser_options, "renderer-process-limit")
      browser
    }) do
      assert_same browser, ScreenshotService.browser
    end
  end

  def test_capture_with_deadline_returns_worker_result
    result = ScreenshotService.stub(:capture_screenshot_with_retry, "png-data") do
      ScreenshotService.send(:capture_with_deadline, "http://example.test", width: 100, height: 100, deadline: 5)
    end

    assert_equal "png-data", result
  end

  def test_capture_with_deadline_force_kills_browser_when_exceeded
    reset_called = false
    slow_capture = ->(*, **) { sleep 2 }

    ScreenshotService.stub(:capture_screenshot_with_retry, slow_capture) do
      ScreenshotService.stub(:reset!, -> { reset_called = true }) do
        error = assert_raises(Timeout::Error) do
          ScreenshotService.send(:capture_with_deadline, "http://example.test", width: 100, height: 100, deadline: 0.2)
        end
        assert_match(/exceeded/, error.message)
      end
    end

    assert reset_called, "expected the browser to be force-killed via reset! on deadline"
  end

  def test_capture_with_deadline_propagates_worker_errors
    boom = ->(*, **) { raise "capture failed" }

    ScreenshotService.stub(:capture_screenshot_with_retry, boom) do
      error = assert_raises(RuntimeError) do
        ScreenshotService.send(:capture_with_deadline, "http://example.test", width: 100, height: 100, deadline: 5)
      end
      assert_equal "capture failed", error.message
    end
  end

  def test_capture_serializes_concurrent_calls
    counter_mutex = Mutex.new
    active = 0
    max_active = 0

    serialized_capture = lambda do |*, **|
      counter_mutex.synchronize do
        active += 1
        max_active = [max_active, active].max
      end
      sleep 0.05
      counter_mutex.synchronize { active -= 1 }
      "AAAA"
    end

    ScreenshotService.stub(:capture_screenshot_with_retry, serialized_capture) do
      threads = 4.times.map do
        Thread.new do
          ScreenshotService.capture("http://example.test", width: 100, height: 100, raw: true)
        end
      end
      threads.each(&:join)
    end

    assert_equal 1, max_active, "MUTEX should prevent concurrent browser access"
  end
end
