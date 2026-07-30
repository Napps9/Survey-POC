# A plain counting semaphore that never blocks: a caller either gets a slot
# immediately or is turned away. Waiting for one would just move thread
# starvation around rather than fix it.
#
# Used to bound how much concurrent AI work this process will take on. There is
# deliberately more than one pool — see LimitsConcurrentStreams (creator report
# streams) and PlayerController (respondent grading). Sharing a single pool
# across those would let one audience starve the other.
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

  # Run the block with a slot held, releasing it however the block ends.
  # Returns the fallback (default nil) without running the block when every
  # slot is busy — callers treat that as "skip the optional work".
  def with_slot(fallback = nil)
    return fallback unless acquire

    begin
      yield
    ensure
      release
    end
  end
end
