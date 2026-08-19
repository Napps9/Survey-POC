# Detects whether Active Storage's local disk root is a genuinely separate
# mounted filesystem, or just an ordinary directory inside the container's
# own (ephemeral) one — the exact failure mode behind the 19 Aug incident,
# where render.yaml declared a persistent disk that had never actually been
# attached to the live service, so every upload lived and died with the
# container it was written to.
#
# A mounted volume gets its own device number; comparing that against the
# device number of its own parent directory is the standard, portable way
# to answer "is this a mount point" without shelling out to `mount` or
# parsing /proc.
#
# Only meaningful for the :local Active Storage service — moving to S3/R2
# would make this whole class of failure moot, which was the alternative
# considered and deliberately not taken (see the 19 Aug incident notes).
module StorageMountCheck
  module_function

  def mounted?
    return true unless Rails.application.config.active_storage.service == :local

    root = Rails.root.join("storage")
    root.exist? && separate_device?(root)
  end

  # Split out for testability: a real "not yet attached" disk is nothing
  # more than this returning false for Rails.root.join("storage") — no
  # actual mount/unmount needed to exercise the comparison itself.
  def separate_device?(path)
    path.stat.dev != path.parent.stat.dev
  end
end
