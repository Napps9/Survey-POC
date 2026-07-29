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

class MemoryWatchdogMonitorTest < ActiveSupport::TestCase
  FakeMemory = Struct.new(:percents) do
    def percent_used  = percents.shift
    def usage_bytes   = 400 * MemoryWatchdog::MB
    def limit_bytes   = 512 * MemoryWatchdog::MB
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
