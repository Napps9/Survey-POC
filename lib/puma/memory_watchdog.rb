# frozen_string_literal: true

# In-container memory monitoring for the production Puma process. Three parts:
#
# * ContainerMemory reads the container's memory usage and limit straight from
#   the cgroup filesystem (v2 first, v1 fallback) — the numbers the kernel's
#   OOM killer actually enforces. Per-process RSS sums (what puma_worker_killer
#   watched before this) both double-count copy-on-write pages and miss sibling
#   processes, so they can look fine right up until the container is killed.
# * RestartThrottle bounds how often a restart may actually be taken, so a
#   threshold the restart cannot clear degrades into an occasional recycle
#   rather than a permanent outage.
# * Monitor decides, sample by sample, when usage has stayed over the restart
#   threshold long enough that a graceful in-place restart beats waiting for
#   the platform to OOM-kill the container mid-request.
#
# Lives under lib/puma (Zeitwerk-ignored, see config/application.rb) because
# it's loaded by config/puma.rb before Rails boots.

module MemoryWatchdog
  MB = 1024 * 1024

  class ContainerMemory
    # cgroup v1 reports "no limit" as a huge page-aligned number rather than a
    # sentinel string; anything this large means the container is uncapped.
    UNLIMITED = 1 << 50

    def initialize(root: "/sys/fs/cgroup")
      @root = root
    end

    # What the cgroup is charged for in total — anonymous memory AND the page
    # cache the kernel has built up from every file the container has read.
    # Reported for the log line only: on its own it is NOT a measure of memory
    # pressure, for the reason spelled out on #usage_bytes.
    def charged_bytes
      read_bytes("memory.current") || read_bytes("memory/memory.usage_in_bytes")
    end

    # The page cache the kernel will drop before it OOM-kills anything. Nil if
    # memory.stat can't be read, which #usage_bytes treats as "assume none".
    def reclaimable_bytes
      read_stat("memory.stat", "inactive_file") ||
        read_stat("memory/memory.stat", "total_inactive_file")
    end

    # The working set: charged memory minus the reclaimable file-backed pages.
    #
    # This subtraction is the whole point of the class. `memory.current` (and
    # v1's `usage_in_bytes`) counts page cache, and page cache grows with every
    # file the container reads — gems, compiled assets, and on this service the
    # Active Storage blobs streamed off the 1GB persistent disk. It is reclaimed
    # under pressure rather than OOM-killing anyone, so it climbs to whatever
    # headroom exists and stays there.
    #
    # Measuring it as usage told the watchdog the container was at 90%+ when the
    # anonymous memory that actually gets a process killed was a fraction of
    # that — and because a Puma re-exec cannot drop a cgroup's page cache, every
    # restart was followed by the same reading, so the watchdog restarted the
    # process every two ticks forever. Whole-site 502s, self-inflicted, and
    # invisible to Sentry because no request ever reached Rails.
    #
    # Charged-minus-inactive_file is the same "working set" cAdvisor and the
    # kubelet use to decide how close a container is to its limit.
    def usage_bytes
      charged = charged_bytes
      return nil unless charged

      [ charged - reclaimable_bytes.to_i, 0 ].max
    end

    def limit_bytes
      value = read_bytes("memory.max") || read_bytes("memory/memory.limit_in_bytes")
      value if value && value < UNLIMITED
    end

    def percent_used
      usage = usage_bytes
      limit = limit_bytes
      return nil unless usage && limit&.positive?

      usage * 100.0 / limit
    end

    # False outside a memory-limited container (local dev, CI) — the watchdog
    # switches itself off rather than guessing.
    def available? = !percent_used.nil?

    private

    def read_bytes(relative_path)
      value = read_file(relative_path)
      return nil unless value
      return nil if value == "max" # cgroup v2's "no limit" sentinel

      Integer(value)
    rescue ArgumentError
      nil
    end

    # cgroup's memory.stat is "key value" per line, in bytes.
    def read_stat(relative_path, key)
      contents = read_file(relative_path)
      return nil unless contents

      line = contents.lines.find { |l| l.split(/\s+/, 2).first == key }
      return nil unless line

      Integer(line.split(/\s+/, 2).last.strip)
    rescue ArgumentError
      nil
    end

    def read_file(relative_path)
      path = File.join(@root, relative_path)
      return nil unless File.readable?(path)

      File.read(path).strip
    rescue SystemCallError
      nil
    end
  end

  # Bounds how often the watchdog may actually restart Puma.
  #
  # A restart only helps when the memory is the process's own. When it isn't —
  # a mis-measured threshold, or a genuine baseline that already exceeds the
  # threshold the moment boot finishes — every restart is followed by the same
  # reading, and the watchdog recycles the process for as long as the container
  # lives. That is strictly worse than doing nothing: the site is down during
  # every drain-and-re-exec, and the condition never clears.
  #
  # The timestamp lives in the environment rather than in memory because Puma's
  # hot restart re-execs this very process — any instance variable is lost at
  # exactly the moment it would be needed. A re-exec inherits its environment,
  # so the stamp survives it; a genuine container restart (an OOM kill, a
  # deploy) starts with a clean environment and is deliberately not throttled.
  class RestartThrottle
    ENV_KEY = "MEMORY_WATCHDOG_LAST_RESTART_AT"

    def initialize(min_interval:, env: ENV, clock: -> { Process.clock_gettime(Process::CLOCK_REALTIME) })
      @min_interval = min_interval
      @env          = env
      @clock        = clock
    end

    # 0 when a restart is allowed now, otherwise the whole seconds still to wait.
    def seconds_until_allowed
      return 0 unless @min_interval.positive?

      last = @env[ENV_KEY].to_f
      return 0 unless last.positive?

      remaining = (last + @min_interval) - @clock.call
      remaining.positive? ? remaining.ceil : 0
    end

    def allow? = seconds_until_allowed.zero?

    def record!
      @env[ENV_KEY] = @clock.call.round.to_s
    end
  end

  # Allows every restart — the default, and what dev/test get unless a throttle
  # is passed in explicitly.
  class NullRestartThrottle
    def seconds_until_allowed = 0
    def allow? = true
    def record! = nil
  end

  class Monitor
    def initialize(memory:, logger:, restarter:, restart_percent: 90, consecutive_breaches: 2,
                   throttle: NullRestartThrottle.new)
      @memory               = memory
      @logger               = logger
      @restarter            = restarter
      @restart_percent      = restart_percent
      @consecutive_breaches = consecutive_breaches
      @throttle             = throttle
      @breaches             = 0
    end

    # One sampling pass: log where the container stands, and trigger the
    # restarter once usage has been at/over the threshold for
    # `consecutive_breaches` consecutive ticks — so a transient spike (a
    # wkhtmltopdf render, an image variant) doesn't recycle the process, but a
    # sustained climb does. Returns :restart, :suppressed, :breach or :ok so the
    # plugin loop and the tests can observe the decision. A restart_percent of 0
    # turns the watchdog into a pure logger.
    def tick
      percent = @memory.percent_used
      return :ok unless percent

      @logger.call(usage_line(percent))

      return reset(:ok) unless @restart_percent.positive? && percent >= @restart_percent

      @breaches += 1
      return :breach if @breaches < @consecutive_breaches

      wait = @throttle.seconds_until_allowed
      return suppressed(wait) if wait.positive?

      @logger.call("MemoryWatchdog: memory has stayed at or above " \
                   "#{@restart_percent}% for #{@breaches} checks — restarting " \
                   "Puma gracefully before the platform OOM-kills the container")
      @breaches = 0
      @throttle.record!
      @restarter.call
      :restart
    end

    private

    # Both numbers, always: the working set is what the threshold is compared
    # against, and the charged figure beside it is what makes a page-cache
    # climb legible in the Render logs instead of looking like a leak.
    def usage_line(percent)
      charged     = @memory.charged_bytes
      reclaimable = charged ? charged - @memory.usage_bytes : nil

      line = format("MemoryWatchdog: container using %dMB of %dMB (%.1f%%)",
                    @memory.usage_bytes / MB, @memory.limit_bytes / MB, percent)
      return line unless reclaimable&.positive?

      line + format(" — working set; %dMB charged, %dMB reclaimable page cache",
                    charged / MB, reclaimable / MB)
    end

    def suppressed(wait)
      @logger.call("MemoryWatchdog: at or above #{@restart_percent}% for " \
                   "#{@breaches} checks, but Puma was restarted too recently — " \
                   "holding off for another #{wait}s. A restart that does not " \
                   "clear the reading means the memory is not this process's to " \
                   "free; recycling it on every breach would only take the site " \
                   "down repeatedly.")
      reset(:suppressed)
    end

    def reset(outcome)
      @breaches = 0
      outcome
    end
  end
end
