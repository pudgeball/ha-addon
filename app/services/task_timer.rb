# frozen_string_literal: true

# Times a piece of recurring background work (config/scheduler.rb) and logs how
# long it took, so the app log shows what the polling loop costs.
#
# A task that runs every few seconds would flood the log with a line per run,
# so with summary_every: its runs are summed up into one line per window
# instead (count, average, slowest), plus a line straight away for any run
# slower than slow_ms. Without summary_every every run gets its own line.
class TaskTimer
  def initialize(name, summary_every: nil, slow_ms: 1000, logger: Rails.logger, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @name = name
    @summary_every = summary_every
    @slow_ms = slow_ms
    @logger = logger
    @clock = clock
    @mutex = Mutex.new
    reset_window(@clock.call)
  end

  def run
    started_at = @clock.call
    yield
  rescue => e
    @logger.warn("[Scheduler] #{@name} failed after #{elapsed_ms(started_at)}ms: #{e.class}: #{e.message}")
    raise
  else
    record(elapsed_ms(started_at))
  end

  private

  def record(ms)
    unless @summary_every
      @logger.info("[Scheduler] #{@name} took #{ms}ms")
      return
    end

    @logger.info("[Scheduler] #{@name} was slow: #{ms}ms") if ms >= @slow_ms
    summary = @mutex.synchronize do
      @count += 1
      @total_ms += ms
      @max_ms = ms if ms > @max_ms
      now = @clock.call
      next unless now - @window_started_at >= @summary_every

      line = "[Scheduler] #{@name}: #{@count} runs in the last #{(now - @window_started_at).round}s, " \
        "avg #{(@total_ms.to_f / @count).round}ms, max #{@max_ms}ms"
      reset_window(now)
      line
    end
    @logger.info(summary) if summary
  end

  def reset_window(now)
    @window_started_at = now
    @count = 0
    @total_ms = 0
    @max_ms = 0
  end

  def elapsed_ms(started_at)
    ((@clock.call - started_at) * 1000).round
  end
end
