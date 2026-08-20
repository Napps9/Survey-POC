require "test_helper"
require "tmpdir"
require Rails.root.join("lib/puma/memory_watchdog")

class MemoryWatchdogContainerMemoryTest < ActiveSupport::TestCase
  test "reads usage, limit and percent from a cgroup v2 layout" do
    in_cgroup_dir do |root|
      File.write(File.join(root, "memory.current"), "268435456\n")
      File.write(File.join(root, "memory.max"), "536870912\n")

      memory = MemoryWatchdog::ContainerMemory.new(root: root)
      assert memory.available?
      assert_equal 268_435_456, memory.usage_bytes
      assert_equal 536_870_912, memory.limit_bytes
      assert_in_delta 50.0, memory.percent_used, 0.01
    end
  end

  test "falls back to a cgroup v1 layout" do
    in_cgroup_dir do |root|
      FileUtils.mkdir_p(File.join(root, "memory"))
      File.write(File.join(root, "memory/memory.usage_in_bytes"), "104857600")
      File.write(File.join(root, "memory/memory.limit_in_bytes"), "536870912")

      memory = MemoryWatchdog::ContainerMemory.new(root: root)
      assert memory.available?
      assert_in_delta 19.5, memory.percent_used, 0.1
    end
  end

  test "unavailable when the v2 limit is the 'max' sentinel" do
    in_cgroup_dir do |root|
      File.write(File.join(root, "memory.current"), "104857600")
      File.write(File.join(root, "memory.max"), "max\n")

      memory = MemoryWatchdog::ContainerMemory.new(root: root)
      assert_nil memory.limit_bytes
      assert_not memory.available?
    end
  end

  test "unavailable when the v1 limit means unlimited" do
    in_cgroup_dir do |root|
      FileUtils.mkdir_p(File.join(root, "memory"))
      File.write(File.join(root, "memory/memory.usage_in_bytes"), "104857600")
      File.write(File.join(root, "memory/memory.limit_in_bytes"), "9223372036854771712")

      memory = MemoryWatchdog::ContainerMemory.new(root: root)
      assert_nil memory.limit_bytes
      assert_not memory.available?
    end
  end

  test "unavailable when no cgroup files exist" do
    in_cgroup_dir do |root|
      memory = MemoryWatchdog::ContainerMemory.new(root: root)
      assert_nil memory.usage_bytes
      assert_nil memory.limit_bytes
      assert_not memory.available?
    end
  end

  test "unreadable garbage reads as unavailable rather than raising" do
    in_cgroup_dir do |root|
      File.write(File.join(root, "memory.current"), "not-a-number")
      File.write(File.join(root, "memory.max"), "536870912")

      memory = MemoryWatchdog::ContainerMemory.new(root: root)
      assert_nil memory.usage_bytes
      assert_not memory.available?
    end
  end

  private

  def in_cgroup_dir(&block)
    Dir.mktmpdir("cgroup", &block)
  end
end

# The subtraction these cover is the whole reason ContainerMemory exists rather
# than a one-line read of memory.current: the charged figure counts page cache,
# which the kernel reclaims instead of OOM-killing, so measuring it as usage
# reports a container as full when its anonymous memory is a fraction of the
# limit — and a Puma re-exec cannot lower it, so every restart is followed by
# the same reading.
class MemoryWatchdogWorkingSetTest < ActiveSupport::TestCase
  test "v2 usage is the charged total minus reclaimable page cache" do
    in_cgroup_dir do |root|
      File.write(File.join(root, "memory.current"), "483183820\n")   # 460MB charged
      File.write(File.join(root, "memory.max"), "536870912\n")       # 512MB limit
      File.write(File.join(root, "memory.stat"), <<~STAT)
        anon 209715200
        file 273468620
        inactive_file 262144000
        active_file 11324620
      STAT

      memory = MemoryWatchdog::ContainerMemory.new(root: root)

      assert_equal 483_183_820, memory.charged_bytes
      assert_equal 262_144_000, memory.reclaimable_bytes
      assert_equal 221_039_820, memory.usage_bytes
      # 90% on the charged figure — the reading that restarted Puma every two
      # ticks — is 41% once the reclaimable cache is taken out.
      assert_in_delta 41.2, memory.percent_used, 0.1
    end
  end

  test "v1 usage subtracts total_inactive_file" do
    in_cgroup_dir do |root|
      FileUtils.mkdir_p(File.join(root, "memory"))
      File.write(File.join(root, "memory/memory.usage_in_bytes"), "2403811328")
      File.write(File.join(root, "memory/memory.limit_in_bytes"), "4294967296")
      File.write(File.join(root, "memory/memory.stat"), <<~STAT)
        cache 30433280
        rss 2494464
        total_cache 2089164800
        total_rss 314322944
        total_inactive_file 1365827584
      STAT

      memory = MemoryWatchdog::ContainerMemory.new(root: root)

      assert_equal 1_037_983_744, memory.usage_bytes
    end
  end

  test "an unreadable memory.stat falls back to the charged figure rather than guessing low" do
    in_cgroup_dir do |root|
      File.write(File.join(root, "memory.current"), "268435456")
      File.write(File.join(root, "memory.max"), "536870912")

      memory = MemoryWatchdog::ContainerMemory.new(root: root)

      assert_nil memory.reclaimable_bytes
      assert_equal 268_435_456, memory.usage_bytes
      assert_in_delta 50.0, memory.percent_used, 0.01
    end
  end

  test "usage never goes negative when the cache figure exceeds the charged one" do
    in_cgroup_dir do |root|
      File.write(File.join(root, "memory.current"), "1000")
      File.write(File.join(root, "memory.max"), "536870912")
      File.write(File.join(root, "memory.stat"), "inactive_file 5000\n")

      assert_equal 0, MemoryWatchdog::ContainerMemory.new(root: root).usage_bytes
    end
  end

  test "a key that is a prefix of another is not mistaken for it" do
    in_cgroup_dir do |root|
      File.write(File.join(root, "memory.current"), "1000000")
      File.write(File.join(root, "memory.max"), "536870912")
      # `file` sorts before `inactive_file` and is a substring of it — a naive
      # match would read 999999 here and report a working set of 1 byte.
      File.write(File.join(root, "memory.stat"), <<~STAT)
        file 999999
        inactive_file 400000
      STAT

      assert_equal 600_000, MemoryWatchdog::ContainerMemory.new(root: root).usage_bytes
    end
  end

  private

  def in_cgroup_dir(&block)
    Dir.mktmpdir("cgroup", &block)
  end
end

# A restart only frees memory that belongs to this process. When it doesn't —
# the mis-measurement above, or a baseline that is genuinely over the threshold
# the moment boot finishes — an unthrottled watchdog recycles Puma on every
# second tick for as long as the container lives, which is strictly worse than
# leaving it alone: the site is down for each drain-and-re-exec and the reading
# never changes.
class MemoryWatchdogRestartThrottleTest < ActiveSupport::TestCase
  test "allows the first restart, then holds off until the interval has passed" do
    now   = 1_000_000.0
    env   = {}
    clock = -> { now }
    throttle = MemoryWatchdog::RestartThrottle.new(min_interval: 600, env: env, clock: clock)

    assert throttle.allow?
    throttle.record!

    now += 60
    assert_not throttle.allow?
    assert_equal 540, throttle.seconds_until_allowed

    now += 540
    assert throttle.allow?
    assert_equal 0, throttle.seconds_until_allowed
  end

  test "the stamp lives in the environment, which is what survives Puma's re-exec" do
    env = {}
    MemoryWatchdog::RestartThrottle.new(min_interval: 600, env: env, clock: -> { 12_345.0 }).record!

    assert_equal "12345", env[MemoryWatchdog::RestartThrottle::ENV_KEY]

    # A fresh process inheriting that environment still sees the stamp...
    inherited = MemoryWatchdog::RestartThrottle.new(min_interval: 600, env: env, clock: -> { 12_400.0 })
    assert_not inherited.allow?

    # ...whereas a genuine container restart starts clean and is not throttled.
    fresh = MemoryWatchdog::RestartThrottle.new(min_interval: 600, env: {}, clock: -> { 12_400.0 })
    assert fresh.allow?
  end

  test "a zero interval disables the throttle" do
    env = { MemoryWatchdog::RestartThrottle::ENV_KEY => "12345" }
    throttle = MemoryWatchdog::RestartThrottle.new(min_interval: 0, env: env, clock: -> { 12_346.0 })

    assert throttle.allow?
  end
end

class MemoryWatchdogMonitorTest < ActiveSupport::TestCase
  # `charged` defaults to the working set, i.e. no reclaimable cache — which
  # keeps the usage line in its short form for every test that isn't about the
  # cache specifically.
  FakeMemory = Struct.new(:percents, :charged) do
    def percent_used  = percents.shift
    def usage_bytes   = 400 * MemoryWatchdog::MB
    def limit_bytes   = 512 * MemoryWatchdog::MB
    def charged_bytes = charged || usage_bytes
  end

  test "restarts only after two consecutive breaches" do
    monitor, restarts = build_monitor(percents: [ 95.0, 95.0 ])

    assert_equal :breach, monitor.tick
    assert_equal 0, restarts.count
    assert_equal :restart, monitor.tick
    assert_equal 1, restarts.count
  end

  test "a dip back under the threshold resets the breach count" do
    monitor, restarts = build_monitor(percents: [ 95.0, 50.0, 95.0 ])

    assert_equal :breach, monitor.tick
    assert_equal :ok, monitor.tick
    assert_equal :breach, monitor.tick # back to one breach, not two
    assert_equal 0, restarts.count
  end

  test "threshold 0 logs but never restarts" do
    monitor, restarts = build_monitor(percents: [ 99.0, 99.0, 99.0 ], restart_percent: 0)

    3.times { assert_equal :ok, monitor.tick }
    assert_equal 0, restarts.count
  end

  test "no reading means no logging and no restart" do
    logs = []
    monitor = MemoryWatchdog::Monitor.new(
      memory:    FakeMemory.new([ nil ]),
      logger:    ->(m) { logs << m },
      restarter: -> { flunk "must not restart" }
    )

    assert_equal :ok, monitor.tick
    assert_empty logs
  end

  test "logs a usage line on every reading" do
    logs = []
    monitor = MemoryWatchdog::Monitor.new(
      memory:    FakeMemory.new([ 78.1 ]),
      logger:    ->(m) { logs << m },
      restarter: -> { }
    )

    monitor.tick
    assert_equal [ "MemoryWatchdog: container using 400MB of 512MB (78.1%)" ], logs
  end

  test "the usage line names the reclaimable cache when there is any" do
    logs = []
    monitor = MemoryWatchdog::Monitor.new(
      memory:    FakeMemory.new([ 78.1 ], 700 * MemoryWatchdog::MB),
      logger:    ->(m) { logs << m },
      restarter: -> { }
    )

    monitor.tick
    assert_equal [ "MemoryWatchdog: container using 400MB of 512MB (78.1%) — " \
                   "working set; 700MB charged, 300MB reclaimable page cache" ], logs
  end

  test "a throttled restart is suppressed, not taken, and monitoring continues" do
    restarts = []
    logs     = []
    monitor  = MemoryWatchdog::Monitor.new(
      memory:    FakeMemory.new([ 95.0, 95.0, 95.0, 95.0 ]),
      logger:    ->(m) { logs << m },
      restarter: -> { restarts << true },
      throttle:  MemoryWatchdog::RestartThrottle.new(
        min_interval: 600,
        env:          { MemoryWatchdog::RestartThrottle::ENV_KEY => "1000000" },
        clock:        -> { 1_000_060.0 }
      )
    )

    assert_equal :breach,     monitor.tick
    assert_equal :suppressed, monitor.tick
    assert_empty restarts
    assert_match(/restarted too recently — holding off for another 540s/, logs.last)

    # Crucially not :restart — the plugin loop breaks on :restart, so returning
    # it here would also stop the watchdog watching.
    assert_equal :breach,     monitor.tick
    assert_equal :suppressed, monitor.tick
    assert_empty restarts
  end

  test "an allowed restart stamps the throttle so the next one is held off" do
    env      = {}
    now      = 2_000_000.0
    restarts = []
    monitor  = MemoryWatchdog::Monitor.new(
      memory:    FakeMemory.new([ 95.0, 95.0 ]),
      logger:    ->(_m) { },
      restarter: -> { restarts << true },
      throttle:  MemoryWatchdog::RestartThrottle.new(min_interval: 600, env: env, clock: -> { now })
    )

    monitor.tick
    assert_equal :restart, monitor.tick
    assert_equal 1, restarts.count
    assert_equal "2000000", env[MemoryWatchdog::RestartThrottle::ENV_KEY]
  end

  private

  def build_monitor(percents:, restart_percent: 90)
    restarts = []
    monitor  = MemoryWatchdog::Monitor.new(
      memory:          FakeMemory.new(percents),
      restart_percent: restart_percent,
      logger:          ->(_message) { },
      restarter:       -> { restarts << true }
    )
    [ monitor, restarts ]
  end
end
