require "test_helper"

class Comms::SendSlotTest < ActiveSupport::TestCase
  BASE = Time.utc(2026, 8, 12, 14, 30) # a Wednesday

  test "no window is a passthrough" do
    assert_equal BASE, Comms::SendSlot.resolve(BASE, nil, [])
  end

  test "an earlier hour rolls to tomorrow, a later one to today" do
    assert_equal Time.utc(2026, 8, 13, 9, 0), Comms::SendSlot.resolve(BASE, 9, [])
    assert_equal Time.utc(2026, 8, 12, 16, 0), Comms::SendSlot.resolve(BASE, 16, [])
  end

  test "disallowed days roll forward to the next allowed one, keeping the hour" do
    # Wednesday → next Monday (ISO 1), at 9:00.
    assert_equal Time.utc(2026, 8, 17, 9, 0), Comms::SendSlot.resolve(BASE, 9, [ 1 ])
    # Wednesday allowed → hour roll only.
    assert_equal Time.utc(2026, 8, 12, 16, 0), Comms::SendSlot.resolve(BASE, 16, [ 3 ])
    # Sunday is ISO 7.
    assert_equal Time.utc(2026, 8, 16, 16, 0), Comms::SendSlot.resolve(BASE, 16, [ 7 ])
  end

  test "the window is interpreted in the configured zone" do
    # 14:30 UTC = 10:30 in New York (UTC-4 in August); hour 12 is still
    # ahead there, so the slot is 12:00 New York = 16:00 UTC.
    slot = Comms::SendSlot.resolve(BASE, 12, [], tz: "America/New_York")
    assert_equal Time.utc(2026, 8, 12, 16, 0), slot.utc
  end
end
