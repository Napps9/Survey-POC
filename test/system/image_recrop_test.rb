require "application_system_test_case"
require "chunky_png"

# Re-cropping an applied image instead of removing and re-uploading it
# (Feedback 17). The crop stage's single final encode destroys the pixels
# outside the frame, so cropApply also keeps the uncropped original
# (image_source) and the crop's place in it (image_crop, fractions of the
# natural size); reopening the stage seeds from both — which is what makes
# zooming back OUT possible at all. A legacy card (a Skip'd upload, anything
# pre-feature) has no source: it still opens, against the stored image itself,
# and says plainly that it can only reposition or zoom in.
#
# The stage is reached through Reposition → "Crop & zoom" now, rather than by
# its own fab: crop is the half of reframing that only a same-origin still can
# have, so it sits behind the one that every image and video can.
#
# Upload mechanics (Node#set, PointerEvents, the rAF waits) follow
# image_crop_test.rb — see the comments there for why each is what it is.
class ImageRecropTest < ApplicationSystemTestCase
  def setup
    super
    @user = User.create!(name: "U", email_address: "rc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org = Organisation.create!(name: "O", slug: "rc-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Recrop", theme: "T", audience_age: "all", key_insight: "x",
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

  def build_fixture_png
    path = Rails.root.join("tmp", "image_recrop_test_#{SecureRandom.hex(4)}.png")
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

  def attach_upload
    find("[data-media-picker-target='fileInput']", visible: false).set(@upload_path)
  end

  def wait_for_crop_stage
    assert_selector "[data-media-picker-target='cropStage']", visible: true
    page.evaluate_async_script(
      "const done = arguments[0]; requestAnimationFrame(() => requestAnimationFrame(done))"
    )
  end

  # Reposition is the entry point; "Crop & zoom" is the hand-off inside it.
  def open_crop_via_reposition
    find(".survey-card-wrap[data-card-type='open_ended'] .media-adjust-fab").click
    assert_selector "[data-media-picker-target='posStage']", visible: true
    click_button "Crop & zoom"
    wait_for_crop_stage
  end

  def apply_and_wait
    click_button "Apply"
    assert_no_selector ".media-modal-backdrop", visible: true
  end

  def card_el_js
    "document.querySelector(\".survey-card-wrap[data-card-type='open_ended']\")"
  end

  def card_dataset(key)
    evaluate_script("#{card_el_js}?.dataset.#{key}")
  end

  def picker_controller_js
    <<~JS
      (window.Stimulus || window.application).getControllerForElementAndIdentifier(
        document.querySelector('[data-controller~="media-picker"]'), "media-picker")
    JS
  end

  def stub_moderation
    fake = Object.new
    fake.define_singleton_method(:call) { |**_kw| { safe: true, reason: "" } }
    stub_method(ImageModerator, :configured?, true) do
      stub_method(ImageModerator, :new, -> { fake }) { yield }
    end
  end

  test "a cropped upload keeps its original, and Adjust crop can zoom back out of it" do
    stub_moderation do
      open_card_media_picker
      attach_upload
      wait_for_crop_stage
      find("[data-media-picker-target='cropZoom']").set(1.6)
      click_button "Use this crop"
      assert_selector "[data-media-picker-target='applyBtn']:not([disabled])"
      apply_and_wait

      # The record is on the card: the kept original and a rect that is a
      # real sub-window (zoomed 1.6x, so well under the full width).
      source = card_dataset("cardImageSource")
      assert source.present?, "the pre-crop original was not kept — zoom-out has nothing to reach"
      assert source.start_with?("/", "data:"),
             "the source must be same-origin (stored path or data URL), got #{source.inspect}"
      crop = JSON.parse(card_dataset("cardImageCrop"))
      assert_operator crop["w"], :>, 0, "the crop rect must have area"
      assert_operator crop["w"], :<, 0.9,
                      "zoomed 1.6x past cover-fit, the crop should be a clear sub-window of the source"

      # The fab revealed itself for the just-applied image — no server render
      # has happened since the page loaded without one.
      assert_selector ".survey-card-wrap[data-card-type='open_ended'] .media-adjust-fab", visible: true

      # …and autosave will carry the record: the serializer reads it off the
      # card's dataset the same way it reads the image itself.
      serialized = evaluate_script(<<~JS)
        (() => {
          const app = window.Stimulus || window.application
          const root = document.querySelector('[data-controller~="survey-editor"]')
          const c = app.getControllerForElementAndIdentifier(root, "survey-editor")
          const card = c.serialize().cards.find(k => k.type === "open_ended")
          return { source: card.image_source, crop: card.image_crop }
        })()
      JS
      assert_equal source, serialized["source"],
                   "serialize() dropped image_source — one autosave would strip the record"
      assert_equal crop, serialized["crop"]

      # Adjust: the stage reopens seeded to the stored crop — zoomed in past
      # cover-fit, exactly where "Use this crop" left it.
      open_crop_via_reposition
      seeded = evaluate_script("(() => { const c = #{picker_controller_js}; return c._cropScale / c._cropMinScale })()")
      assert_in_delta 1.6, seeded, 0.1,
                      "Adjust should reopen AT the stored crop, not reset to cover-fit"

      # The whole point: zoom back OUT past the shipped crop, to cover-fit —
      # possible only because the original was kept.
      find("[data-media-picker-target='cropZoom']").set(1)
      click_button "Use this crop"
      # Confirming the crop IS the apply here — the picker's tabs and its
      # Apply button were never on screen in the Adjust flow.
      assert_no_selector ".media-modal-backdrop", visible: true

      wider = JSON.parse(card_dataset("cardImageCrop"))
      assert_operator wider["w"], :>, crop["w"] * 1.3,
                      "zooming out to cover-fit should widen the stored rect " \
                      "(#{crop['w']} -> #{wider['w']}); if it didn't, the re-crop drew from " \
                      "the cropped image instead of the kept original"
      assert card_dataset("cardImageSource").present?, "the source must survive a re-crop"
    end
  end

  test "a Skip'd upload has no record, and Adjust degrades honestly to reposition-and-zoom-in" do
    stub_moderation do
      open_card_media_picker
      attach_upload
      wait_for_crop_stage
      click_button "Skip"
      assert_selector "[data-media-picker-target='applyBtn']:not([disabled])"
      apply_and_wait

      # Skip stores the whole original AS the image — there is no separate
      # source to keep, and stamping one would be the same bytes twice.
      assert card_dataset("cardImageSource").blank?,
             "a Skip'd upload needs no re-crop record: its stored image IS the original"

      # Adjust still works — against the stored image, which caps zoom-out —
      # and the stage says so instead of a slider that silently stops.
      open_crop_via_reposition
      assert_selector "[data-media-picker-target='cropHintLegacy']", visible: true
      hidden = evaluate_script("document.querySelector(\"[data-media-picker-target='cropHint']\").hidden")
      assert hidden, "the ordinary hint should stand aside for the legacy one"
      skip_label = find("[data-media-picker-target='cropSkipBtn']").text
      assert_equal "Cancel", skip_label,
                   "with nothing pending, skipping the Adjust stage is backing out — the button must say so"

      # Cancel steps BACK to the reposition stage it was reached from — the
      # creator asked to reframe, not to leave the modal — and a second cancel
      # leaves the card exactly as it came.
      before = card_dataset("cardImage")
      click_button "Cancel"
      assert_selector "[data-media-picker-target='posStage']", visible: true
      assert_no_selector "[data-media-picker-target='cropStage']", visible: true
      click_button "Cancel"
      assert_no_selector ".media-modal-backdrop", visible: true
      assert_equal before, card_dataset("cardImage")
      assert card_dataset("cardImageSource").blank?
      refute card_dataset("cardFocalX").present?, "backing out must not reposition the card either"
    end
  end
end
