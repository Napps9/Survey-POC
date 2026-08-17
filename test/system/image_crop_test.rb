require "application_system_test_case"
require "chunky_png"

# Crop/reposition stage (2.10): media_picker_controller.js#_openCropStage sits
# between decode and stash for a fixed-ratio slot (card/background/tap-option
# — CROP_RATIO mirrors PexelsClient::CROP_FOR). Uploads only — library and
# Pexels picks already arrive pre-cropped server-side, so this suite only
# exercises the Upload tab.
#
# File attachment goes through Node#set directly rather than Capybara's
# attach_file: the input carries no name/id/label text to lock a locator to,
# and Cuprite's file-input handling (CDP's file-select command) doesn't need
# the element visible the way some attach_file paths do, so there's nothing
# make_visible would add here.
#
# The drag itself is dispatched as synthetic PointerEvents rather than driven
# through Capybara/Cuprite's own drag_to — not because it's unreliable here
# (drag_to is CDP mouse simulation, which genuinely does dispatch pointer
# events, unlike the *native HTML5* dragstart/dragover/drop sequence that
# card_drag_reorder_test.rb found CDP mouse simulation could not reliably
# trigger) but because dispatching the events directly lets the test assert
# the exact offset the controller computed, deterministically.
class ImageCropTest < ApplicationSystemTestCase
  def setup
    super
    @user = User.create!(name: "U", email_address: "crop-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org = Organisation.create!(name: "O", slug: "crop-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Crop", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "open_ended", "text" => "Tell us more" }
      ]
    )
    @upload_path = build_fixture_png
  end

  def teardown
    FileUtils.rm_f(@upload_path)
    super
  end

  # A 400×300 (4:3) PNG — deliberately a different aspect ratio than any
  # CROP_RATIO target, so a forced crop is visibly distinguishable from the
  # plain (Skip) downscale, which keeps the source's own 4:3 shape.
  def build_fixture_png
    path = Rails.root.join("tmp", "image_crop_test_#{SecureRandom.hex(4)}.png")
    img = ChunkyPNG::Image.new(400, 300, ChunkyPNG::Color.rgb(220, 20, 60))
    img.rect(40, 40, 360, 260, ChunkyPNG::Color.rgb(30, 144, 255), ChunkyPNG::Color.rgb(30, 144, 255))
    img.save(path)
    path.to_s
  end

  def open_card_media_picker
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Tell us more"
    find(".survey-card-wrap[data-card-type='open_ended'] .split-left-design-prompt").click
    find("[data-tab='upload']").click
  end

  def attach_upload(path = @upload_path)
    find("[data-media-picker-target='fileInput']", visible: false).set(path)
  end

  # The stage only appears once the picked file has actually decoded (an
  # async Image load), so this has to be a real wait — assert_selector
  # retries — not a one-shot check. _layoutCrop itself lands one rAF after
  # that (the frame's rendered size depends on the aspect-ratio just being
  # applied), so wait a further two frames the same way player_keyboard_test
  # does for its own rAF-deferred layout — otherwise a zoom/pan issued right
  # after the stage becomes visible can land before _cropScale is set.
  def wait_for_crop_stage
    assert_selector "[data-media-picker-target='cropStage']", visible: true
    page.evaluate_async_script(
      "const done = arguments[0]; requestAnimationFrame(() => requestAnimationFrame(done))"
    )
  end

  # applyImage() is async (moderation, then persisting the upload) before it
  # ever sets card.dataset.cardImage and closes the modal — so "click Apply"
  # is not "the card now carries the image" the way it is for a synchronous
  # action. Waiting for the backdrop to close is the one signal that async
  # chain has actually finished.
  def apply_and_wait
    click_button "Apply"
    assert_no_selector ".media-modal-backdrop", visible: true
  end

  def pending_image_dims_from(data_url)
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      const img = new Image()
      img.onload = () => done([ img.naturalWidth, img.naturalHeight ])
      img.src = #{data_url.to_json}
    JS
  end

  def card_image_data_url
    evaluate_script(<<~JS)
      document.querySelector(".survey-card-wrap[data-card-type='open_ended']").dataset.cardImage
    JS
  end

  def crop_offset
    evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="media-picker"]')
        const c    = app.getControllerForElementAndIdentifier(root, "media-picker")
        return [ c._cropOffsetX, c._cropOffsetY ]
      })()
    JS
  end

  # applyImage() moderates every data: URL upload before it stashes it — this
  # test isn't exercising moderation, so stub it the same way
  # surveys_moderate_image_test.rb does, rather than reaching the real
  # ImageModerator (which would try a real Anthropic call using the test
  # env's stub API key).
  def stub_moderation
    fake = Object.new
    fake.define_singleton_method(:call) { |**_kw| { safe: true, reason: "" } }
    stub_method(ImageModerator, :configured?, true) do
      stub_method(ImageModerator, :new, -> { fake }) { yield }
    end
  end

  test "choosing an upload for a card opens a crop stage at the card's 9:16 aspect" do
    open_card_media_picker
    attach_upload
    wait_for_crop_stage

    ratio = evaluate_script(
      "document.querySelector(\"[data-media-picker-target='cropFrame']\").style.aspectRatio"
    )
    assert_equal "720 / 1280", ratio

    # The ordinary tabs/body/foot sit this out while the crop stage owns the
    # modal's content area.
    assert evaluate_script("document.querySelector('.media-modal-tabs').hidden")
    assert evaluate_script("document.querySelector('.media-modal-foot').hidden")
  end

  test "panning and zooming, then applying, stores an image reshaped to the card's target size" do
    stub_moderation do
      open_card_media_picker
      attach_upload
      wait_for_crop_stage

      # Zoom in past cover-fit, then pan — dispatched as real PointerEvents
      # against the actual listeners (see class comment for why this, not
      # drag_to, drives the assertion).
      find("[data-media-picker-target='cropZoom']").set(1.6)
      offset_before = crop_offset
      evaluate_script(<<~JS)
        (() => {
          const frame = document.querySelector("[data-media-picker-target='cropFrame']")
          const rect  = frame.getBoundingClientRect()
          const cx    = rect.left + rect.width / 2
          const cy    = rect.top + rect.height / 2
          const fire  = (type, x, y) => frame.dispatchEvent(new PointerEvent(type, {
            bubbles: true, cancelable: true, pointerId: 1, clientX: x, clientY: y
          }))
          fire("pointerdown", cx, cy)
          fire("pointermove", cx - 12, cy - 9)
          fire("pointerup", cx - 12, cy - 9)
        })()
      JS
      assert_not_equal offset_before, crop_offset, "the pointer drag should have panned the crop"

      click_button "Use this crop"
      assert_no_selector "[data-media-picker-target='cropStage']", visible: true
      assert_selector "[data-media-picker-target='applyBtn']:not([disabled])"
      apply_and_wait

      # _persistUpload (applyImage's last await) hands the moderated data: URL
      # to the server, which stores it and hands back a short same-origin
      # path — so by now this is normally that path, not the data: URL the
      # crop itself produced. Either decodes the same way.
      data_url = card_image_data_url
      assert data_url.present?, "the crop should have applied to the card"
      assert_equal [ 720, 1280 ], pending_image_dims_from(data_url)
    end
  end

  test "Skip preserves today's plain-downscale behaviour — the source's own aspect, uncropped" do
    stub_moderation do
      open_card_media_picker
      attach_upload
      wait_for_crop_stage

      click_button "Skip"
      assert_no_selector "[data-media-picker-target='cropStage']", visible: true
      assert_selector "[data-media-picker-target='applyBtn']:not([disabled])"
      apply_and_wait

      # 400×300 source, well under MAX_EDGE — stored at its own native size and
      # aspect, exactly like before this feature existed.
      assert_equal [ 400, 300 ], pending_image_dims_from(card_image_data_url)
    end
  end

  test "an SVG upload bypasses the crop stage entirely" do
    open_card_media_picker
    svg_path = Rails.root.join("tmp", "image_crop_test_#{SecureRandom.hex(4)}.svg")
    File.write(svg_path, '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>')

    begin
      attach_upload(svg_path.to_s)
      assert_selector "[data-media-picker-target='applyBtn']:not([disabled])"
      assert_no_selector "[data-media-picker-target='cropStage']", visible: true
    ensure
      FileUtils.rm_f(svg_path)
    end
  end
end
