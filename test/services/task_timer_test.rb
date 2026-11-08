# frozen_string_literal: true

require "test_helper"

class TaskTimerTest < ActiveSupport::TestCase
  setup do
    @now = 0.0
    @clock = -> { @now }
    @log = StringIO.new
    @logger = Logger.new(@log)
    @logger.formatter = ->(severity, _time, _prog, msg) { "#{severity} #{msg}\n" }
  end

  test "logs every run when there is no summary window" do
    timer = TaskTimer.new("1m fetch_weather", logger: @logger, clock: @clock)

    timer.run { @now += 0.25 }

    assert_equal "INFO [Scheduler] 1m fetch_weather took 250ms\n", @log.string
  end

  test "sums frequent runs into one line per window" do
    timer = TaskTimer.new("2s fetch_states", summary_every: 60, logger: @logger, clock: @clock)

    timer.run { @now += 0.1 }
    @now += 29
    timer.run { @now += 0.3 }
    assert_empty @log.string

    @now += 31
    timer.run { @now += 0.2 }

    assert_equal "INFO [Scheduler] 2s fetch_states: 3 runs in the last 61s, avg 200ms, max 300ms\n", @log.string

    @log.truncate(0)
    @log.rewind
    timer.run { @now += 0.1 }
    assert_empty @log.string, "a new window starts after each summary"
  end

  test "logs a slow run straight away even inside a summary window" do
    timer = TaskTimer.new("2s fetch_states", summary_every: 60, slow_ms: 1000, logger: @logger, clock: @clock)

    timer.run { @now += 1.5 }

    assert_equal "INFO [Scheduler] 2s fetch_states was slow: 1500ms\n", @log.string
  end

  test "logs a failure with its duration and re-raises it" do
    timer = TaskTimer.new("1m fetch_calendars", logger: @logger, clock: @clock)

    assert_raises(RuntimeError) do
      timer.run do
        @now += 0.04
        raise "boom"
      end
    end

    assert_equal "WARN [Scheduler] 1m fetch_calendars failed after 40ms: RuntimeError: boom\n", @log.string
  end
end
