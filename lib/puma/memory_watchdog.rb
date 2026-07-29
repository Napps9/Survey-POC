# frozen_string_literal: true

# In-container memory monitoring for the production Puma process. Two parts:
#
# * ContainerMemory reads the container's memory usage and limit straight from
#   the cgroup filesystem (v2 first, v1 fallback) — the numbers the kernel's
#   OOM killer actually enforces. Per-process RSS sums (what puma_worker_killer
#   watched before this) both double-count copy-on-write pages and miss sibling
#   processes, so they can look fine right up until the container is killed.
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

    def usage_bytes
      read_bytes("memory.current") || read_bytes("memory/memory.usage_in_bytes")
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
      path = File.join(@root, relative_path)
      return nil unless File.readable?(path)

      value = File.read(path).strip
      return nil if value == "max" # cgroup v2's "no limit" sentinel

      Integer(value)
    rescue SystemCallError, ArgumentError
      nil
    end
  end

  class Monitor
    def initialize(memory:, logger:, restarter:, restart_percent: 90, consecutive_breaches: 2)
      @memory               = memory
      @logger               = logger
      @restarter            = restarter
      @restart_percent      = restart_percent
      @consecutive_breaches = consecutive_breaches
      @breaches             = 0
    end

    # One sampling pass: log where the container stands, and trigger the
    # restarter once usage has been at/over the threshold for
    # `consecutive_breaches` consecutive ticks — so a transient spike (a
    # wkhtmltopdf render, an image variant) doesn't recycle the process, but a
    # sustained climb does. Returns :restart, :breach or :ok so the plugin
    # loop and the tests can observe the decision. A restart_percent of 0
    # turns the watchdog into a pure logger.
    def tick
      percent = @memory.percent_used
      return :ok unless percent

      @logger.call(format("MemoryWatchdog: container using %dMB of %dMB (%.1f%%)",
                          @memory.usage_bytes / MB, @memory.limit_bytes / MB, percent))

      if @restart_percent.positive? && percent >= @restart_percent
        @breaches += 1
        return :breach if @breaches < @consecutive_breaches

        @logger.call("MemoryWatchdog: memory has stayed at or above " \
                     "#{@restart_percent}% for #{@breaches} checks — restarting " \
                     "Puma gracefully before the platform OOM-kills the container")
        @breaches = 0
        @restarter.call
        :restart
      else
        @breaches = 0
        :ok
      end
    end
  end
end
