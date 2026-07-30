require "test_helper"

# Brand-library tiles used to link lazily-processed variants: viewing a library
# of 60 assets meant 60 representation requests, each spawning a libvips
# transform on a Puma request thread. On a 512MB instance with three threads
# that's a burst of native memory — the shape that trips the memory watchdog,
# and the last of the P0-3 inline work.
#
# The variant is preprocessed at upload instead, so viewing the library resolves
# to an already-built blob.
#
# Nothing here PERFORMS a transform: that needs libvips, which lives in the
# production image but not necessarily wherever the suite runs. What's asserted
# is the mechanism — the declaration, and the job the attach queues — plus what
# the pages actually render.
class BrandAssetThumbnailsTest < ActionDispatch::IntegrationTest
  IMAGE = Rails.root.join("public/icon.png")

  def setup
    @user = User.create!(name: "U", email_address: "ba-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "ba-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
  end

  def sign_in!
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def attach!(filename: "brand.png", content_type: "image/png", io: nil)
    @org.assets.attach(io: io || File.open(IMAGE), filename: filename, content_type: content_type)
    @org.assets.reload.last
  end

  # ── The declaration ───────────────────────────────────────────────────────

  test "the thumb variant is declared, and preprocessed rather than lazy" do
    reflection = @org.attachment_reflections["assets"]
    assert_includes reflection.named_variants.keys, :thumb

    variant = reflection.named_variants[:thumb]
    assert_equal true, variant.instance_variable_get(:@preprocessed),
                 "lazy would put a libvips transform on a request thread per tile"
  end

  test "the thumbnail is bounded to the size the tiles actually render" do
    transformations = @org.attachment_reflections["assets"]
              .named_variants[:thumb].transformations
    assert_equal [ Organisation::ASSET_THUMB_LIMIT, Organisation::ASSET_THUMB_LIMIT ],
                 transformations[:resize_to_limit]
  end

  # The mechanism: attaching queues the transform, so there's nothing left to do
  # when someone views the library.
  test "attaching an image queues its thumbnail transform" do
    assert_enqueued_with(job: ActiveStorage::TransformJob) { attach! }
  end

  test "every attached image queues its own" do
    assert_enqueued_jobs 3, only: ActiveStorage::TransformJob do
      3.times { |i| attach!(filename: "b#{i}.png") }
    end
  end

  # ── What the pages link to ────────────────────────────────────────────────

  test "the branding page links one representation per asset" do
    3.times { |i| attach!(filename: "b#{i}.png") }
    sign_in!

    get organisation_memberships_path(@org)
    assert_response :success
    assert_equal 3, response.body.scan("/rails/active_storage/representations/").size
  end

  test "the editor's media picker links them too" do
    attach!
    sign_in!
    survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                  default_locale: "en", locales: [ "en" ],
                                  cards: [ { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ])

    get survey_path(survey)
    assert_response :success
    assert_includes response.body, "/rails/active_storage/representations/"
  end

  # Rendering must never be what triggers the work — that was the whole bug.
  test "rendering the library queues no transforms of its own" do
    attach!
    sign_in!

    assert_no_enqueued_jobs(only: ActiveStorage::TransformJob) do
      get organisation_memberships_path(@org)
    end
    assert_response :success
  end

  test "an empty library renders no representations at all" do
    sign_in!
    get organisation_memberships_path(@org)
    assert_response :success
    assert_not_includes response.body, "/rails/active_storage/representations/"
  end
end

# Assets uploaded before the :thumb variant was declared have no preprocessed
# thumbnail, so the first person to open their library would still pay for a
# lazy transform per tile. The backfill task queues the missing ones.
class BrandAssetThumbBackfillTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  IMAGE = Rails.root.join("public/icon.png")

  setup do
    # Only this rake file, not Rails.application.load_tasks — that pulls in every
    # task in lib/tasks, and re-runs their top-level code, which is noise (and
    # constant-redefinition warnings) for no benefit here. :environment is
    # stubbed because the suite is already booted.
    unless Rake::Task.task_defined?("brand_assets:backfill_thumbs")
      Rake::Task.define_task(:environment)
      load Rails.root.join("lib/tasks/brand_assets.rake")
    end
    @task = Rake::Task["brand_assets:backfill_thumbs"]
    @task.reenable
    @org = Organisation.create!(name: "O", slug: "bf-#{SecureRandom.hex(3)}")
  end

  def attach!(filename: "brand.png", content_type: "image/png", io: nil)
    @org.assets.attach(io: io || File.open(IMAGE), filename: filename, content_type: content_type)
    @org.assets.reload.last
  end

  test "it queues a transform for an asset with no thumbnail yet" do
    attach!
    clear_enqueued_jobs   # pretend it predates the declaration

    assert_enqueued_jobs 1, only: ActiveStorage::TransformJob do
      capture_io { @task.invoke(@org.slug) }
    end
  end

  test "it skips vector art, which has no variant to build" do
    svg = StringIO.new("<svg xmlns='http://www.w3.org/2000/svg'><rect width='1' height='1'/></svg>")
    attach!(filename: "logo.svg", content_type: "image/svg+xml", io: svg)
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: ActiveStorage::TransformJob) do
      capture_io { @task.invoke(@org.slug) }
    end
  end

  test "an unknown organisation aborts rather than running over everything" do
    assert_raises(SystemExit) { capture_io { @task.invoke("no-such-org") } }
  end
end
