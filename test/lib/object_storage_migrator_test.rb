require "test_helper"

# Disk → Disk (`test` → `test_bucket`, both in config/storage.yml): the exact
# copy / flip / roll-back mechanics production uses for disk → bucket, with no
# bucket and no network.
class ObjectStorageMigratorTest < ActiveSupport::TestCase
  BUCKET_ROOT = Rails.root.join("tmp/storage_bucket")

  setup do
    # Only this test's blobs count. delete_all skips callbacks, so nothing is
    # purged from disk; the rows roll back with the transaction.
    ActiveStorage::Attachment.delete_all
    ActiveStorage::Blob.delete_all
    FileUtils.rm_rf(BUCKET_ROOT)
  end

  teardown { FileUtils.rm_rf(BUCKET_ROOT) }

  def make_blob(bytes = "png-bytes-#{SecureRandom.hex(4)}")
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: "card.png", content_type: "image/png")
  end

  def migrator(**opts)
    ObjectStorage::Migrator.new(from: :test, to: :test_bucket, io: StringIO.new, **opts)
  end

  def service(name)
    ActiveStorage::Blob.services.fetch(name)
  end

  test "copies each blob to the destination, verified, and flips service_name" do
    hello = make_blob("hello")
    world = make_blob("world")

    result = migrator.run!

    assert_equal 2, result.total
    assert_equal 2, result.copied
    assert result.ok?, result.to_s
    [ hello, world ].each do |blob|
      blob.reload
      assert_equal "test_bucket", blob.service_name
      assert service(:test_bucket).exist?(blob.key)
      assert service(:test).exist?(blob.key), "source bytes are kept so rollback is a pure flip"
    end
    assert_equal "hello", hello.download
    assert_equal "world", world.download
  end

  test "is idempotent and resumable" do
    blob = make_blob
    assert_equal 1, migrator.run!.copied

    again = migrator.run!
    assert_equal 0, again.total
    assert_equal 0, again.copied

    # Bytes already in the destination (an interrupted earlier run): flip only.
    blob.update_columns(service_name: "test")
    resumed = migrator.run!
    assert_equal 1, resumed.flipped
    assert_equal 0, resumed.copied
    assert_equal "test_bucket", blob.reload.service_name
  end

  test "a dry run copies nothing and flips nothing, but reports what it would do" do
    blob = make_blob

    result = migrator(dry_run: true).run!

    assert_equal 1, result.copied
    assert_equal "test", blob.reload.service_name
    refute service(:test_bucket).exist?(blob.key)
  end

  test "a blob whose bytes are missing from the source is reported, not flipped" do
    blob = make_blob
    service(:test).delete(blob.key)

    result = migrator.run!

    assert_equal 1, result.missing
    refute result.ok?
    assert_equal "test", blob.reload.service_name
  end

  test "rollback points blobs back at the source wherever it still has the bytes" do
    blob = make_blob("keep")
    migrator.run!
    assert_equal "test_bucket", blob.reload.service_name

    result = migrator.rollback!

    assert_equal 1, result.flipped
    assert_equal "test", blob.reload.service_name
    assert_equal "keep", blob.download
  end

  test "rollback leaves alone a blob that exists only in the destination" do
    blob = make_blob
    migrator.run!
    service(:test).delete(blob.key) # an upload made after the switch has no disk copy

    result = migrator.rollback!

    assert_equal 1, result.skipped
    assert_equal 0, result.flipped
    assert_equal "test_bucket", blob.reload.service_name
  end

  test "verify passes only once nothing is left on the source" do
    make_blob
    refute migrator.verify
    migrator.run!
    assert migrator.verify
  end

  test "refuses to migrate a service onto itself" do
    assert_raises(ArgumentError) { ObjectStorage::Migrator.new(from: :test, to: "test") }
  end
end
