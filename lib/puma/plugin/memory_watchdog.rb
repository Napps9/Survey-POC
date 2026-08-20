# frozen_string_literal: true

require "puma/plugin"
require_relative "../memory_watchdog"

# Watches the container's working set (charged cgroup memory minus reclaimable
# page cache — see ContainerMemory#usage_bytes) against the cgroup limit the
# kernel OOM killer enforces, from a background thread in the Puma process.
# Logs a usage line each interval so the Render logs always show where the
# container really stands, and hot-restarts Puma once usage has stayed over the
# threshold for two consecutive checks — a graceful drain-and-re-exec instead of
# a SIGKILL mid-request. Outside a memory-limited container (dev, CI) it
# switches itself off. Tunables, all optional:
#
#   MEMORY_WATCHDOG_RESTART_PERCENT — default 90; 0 logs without restarting.
#   MEMORY_WATCHDOG_INTERVAL_SECONDS — default 30.
#   MEMORY_WATCHDOG_MIN_RESTART_INTERVAL_SECONDS — default 600; 0 disables the
#     throttle. The floor between two watchdog restarts, so a threshold a
#     restart cannot clear costs an occasional recycle rather than a permanent
#     one every two ticks. See MemoryWatchdog::RestartThrottle.
Puma::Plugin.create do
  def start(launcher)
    memory = MemoryWatchdog::ContainerMemory.new
    unless memory.available?
      launcher.log_writer.log "MemoryWatchdog: no cgroup memory limit found — monitoring disabled"
      return
    end

    monitor = MemoryWatchdog::Monitor.new(
      memory:          memory,
      restart_percent: Integer(ENV.fetch("MEMORY_WATCHDOG_RESTART_PERCENT", 90)),
      logger:          ->(message) { launcher.log_writer.log(message) },
      restarter:       -> { launcher.restart },
      throttle:        MemoryWatchdog::RestartThrottle.new(
        min_interval: Integer(ENV.fetch("MEMORY_WATCHDOG_MIN_RESTART_INTERVAL_SECONDS", 600))
      )
    )
    interval = Integer(ENV.fetch("MEMORY_WATCHDOG_INTERVAL_SECONDS", 30))

    in_background do
      loop do
        sleep interval
        break if monitor.tick == :restart
      end
    end
  end
end
