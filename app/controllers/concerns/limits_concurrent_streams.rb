# Caps how many AI streaming responses can be in flight in this process at once.
#
# The streaming endpoints (insights summary, per-segment text summary, report,
# results chat) write text to the client as Claude produces it. That incremental
# reveal is the point of them, so unlike the rest of P0-3 they can't simply move
# to a background job without losing the feature. But they hold a Puma thread
# for as long as Claude keeps writing, and with three threads on one worker a
# handful of them starves everything else — the exact failure AnthropicHelpers
# describes, where pages that never touch Claude start returning 502s.
#
# So instead of removing the streams, bound them: keep enough threads free that
# the rest of the app stays responsive no matter how many people are watching a
# report write itself. A caller who arrives with no slot free is told to retry in
# a moment, which is a far better outcome than the whole instance going down.
#
# The counter is per-process, which is the right granularity: the resource being
# protected is this process's thread pool. Under multiple Puma workers each gets
# its own pool and its own cap.
module LimitsConcurrentStreams
  extend ActiveSupport::Concern

  # Reserve two threads for ordinary requests. On the default 3-thread instance
  # that leaves one streaming slot — deliberately conservative, because both
  # summaries and the report are cached after their first run, so genuinely
  # concurrent streaming is rare and an occasional retry is cheap next to an
  # app-wide outage. Tunable if the instance grows.
  def self.slot_count
    configured = ENV["AI_STREAM_SLOTS"].presence&.to_i
    return configured if configured&.positive?

    [ Integer(ENV.fetch("RAILS_MAX_THREADS", 3)) - 2, 1 ].max
  end

  # A plain counting semaphore that never blocks: a caller either gets a slot
  # immediately or is turned away. Waiting for one would just move the thread
  # starvation rather than fix it.
  class SlotPool
    def initialize(size)
      @size  = size
      @taken = 0
      @mutex = Mutex.new
    end

    def acquire
      @mutex.synchronize do
        return false if @taken >= @size

        @taken += 1
        true
      end
    end

    def release
      @mutex.synchronize { @taken -= 1 if @taken.positive? }
    end

    def available = @mutex.synchronize { @size - @taken }
  end

  POOL = SlotPool.new(slot_count)

  BUSY_MESSAGE = "Too many reports are being written right now — please try again in a moment.".freeze

  class_methods do
    # Declare which actions stream. An around_action rather than a guard at the
    # top of each action, so the slot is released however the action ends —
    # including the ClientDisconnected that Live raises when someone closes the
    # tab mid-stream. A leaked slot would shrink the pool permanently until the
    # process restarted, which is a worse bug than the one this fixes.
    def limit_concurrent_streams(**options)
      around_action :with_stream_slot, **options
    end
  end

  private

  def with_stream_slot
    unless POOL.acquire
      render plain: BUSY_MESSAGE, status: :service_unavailable
      return
    end

    begin
      yield
    ensure
      POOL.release
    end
  end
end
