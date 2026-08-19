require "test_helper"

class StorageMountCheckTest < ActiveSupport::TestCase
  test "separate_device? is false for an ordinary directory (not a mount point)" do
    # Rails.root itself is never a mount point in a plain checkout — same
    # device as its own parent, exactly the "disk never attached" state.
    refute StorageMountCheck.separate_device?(Rails.root)
  end

  test "separate_device? is true for a genuine mount point" do
    # /proc is a separate pseudo-filesystem mounted on / on every Linux box,
    # including this one — a portable stand-in for a real attached disk
    # that needs no mount/unmount setup to exercise the positive case.
    assert StorageMountCheck.separate_device?(Pathname.new("/proc"))
  end

  test "mounted? is true outright when Active Storage isn't using the local disk" do
    # Exercises the early-return with no stubbing at all: the test
    # environment's own service is :test (config/storage.yml), not :local.
    assert_not_equal :local, Rails.application.config.active_storage.service
    assert StorageMountCheck.mounted?
  end
end
