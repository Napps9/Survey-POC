require "application_system_test_case"

# Reposition — the reframing that works on every image and piece of content,
# not only on uploads.
#
# The crop stage re-encodes on a canvas, so it can only ever serve a
# same-origin still: a Pexels photo taints the canvas and a video has no canvas
# path at all. Those were exactly the cards a creator could not reframe ("I
# need the ability in the editor to reposition every image and piece of
# content — at the moment I can only do it with uploads"). Repositioning stores
# WHERE the media sits in the frame instead (focal_x/focal_y on a card hero,
# one entry of option_focals on a tap statement), which nothing about the
# medium's origin can stop.
#
# The drag is dispatched as synthetic PointerEvents rather than through
# Capybara's drag_to, for the reason image_crop_test.rb gives: it lets the test
# assert the exact position the controller computed, deterministically.
class MediaRepositionTest < ApplicationSystemTestCase
  PEXELS_IMAGE = "https://images.pexels.com/photos/123/pexels-photo-123.jpeg?auto=compress&cs=tinysrgb&w=720&h=1280&fit=crop".freeze
  PEXELS_VIDEO = "https://videos.pexels.com/video-files/123/hd.mp4".freeze
  LIBRARY_IMAGE = "/assets/verto-library/backgrounds/nature.jpg".freeze

  def setup
    super
    @user = User.create!(name: "U", email_address: "pos-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @org = Organisation.create!(name: "O", slug: "pos-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
  end

  def build_survey(cards)
    @org.surveys.create!(
      title: "Reposition", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ] + cards
    )
  end

  def open_editor(survey)
    sign_in_as(@user)
    visit survey_path(survey)
    dismiss_cookie_banner
  end

  def card_dataset(type, key)
    evaluate_script(%(document.querySelector(".survey-card-wrap[data-card-type='#{type}']")?.dataset.#{key}))
  end

  # The stage sizes its frame from the live slot and measures the media's
  # natural size asynchronously — both have to have landed before a drag means
  # anything, so this is a real wait plus the controller's own rAF.
  def wait_for_pos_stage
    assert_selector "[data-media-picker-target='posStage']", visible: true
    page.evaluate_async_script(
      "const done = arguments[0]; requestAnimationFrame(() => requestAnimationFrame(done))"
    )
  end

  # Force the overflow the controller would have measured from a real decode.
  # The fixtures here point at Pexels and at library paths that don't resolve
  # in the test environment, so nothing loads and both axes measure zero —
  # which is honest (an unmeasured axis must not drag) but leaves nothing to
  # assert about the drag maths itself.
  def seed_overflow(x, y)
    evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="media-picker"]')
        const c    = app.getControllerForElementAndIdentifier(root, "media-picker")
        c._posOverflowX = #{x}
        c._posOverflowY = #{y}
      })()
    JS
  end

  # A picture whose shape exactly matches the frame — the case that hides
  # nothing at cover-fit, and so the case the zoom exists for. Derived from the
  # frame's own measured box so it is an exact match whatever the panel's
  # rendered size happens to be, and fed through the controller's own
  # _measurePos so the maths under test is the shipped maths.
  def seed_natural_matching_frame
    evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="media-picker"]')
        const c = app.getControllerForElementAndIdentifier(root, "media-picker")
        const r = document.querySelector("[data-media-picker-target='posFrame']").getBoundingClientRect()
        c._measurePos(Math.round(r.width * 4), Math.round(r.height * 4))
      })()
    JS
  end

  def pos_overflow
    evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="media-picker"]')
        const c = app.getControllerForElementAndIdentifier(root, "media-picker")
        return [ c._posOverflowX, c._posOverflowY ]
      })()
    JS
  end

  def drag_pos_frame(dx, dy)
    evaluate_script(<<~JS)
      (() => {
        const frame = document.querySelector("[data-media-picker-target='posFrame']")
        const rect  = frame.getBoundingClientRect()
        const cx    = rect.left + rect.width / 2
        const cy    = rect.top + rect.height / 2
        const fire  = (type, x, y) => frame.dispatchEvent(new PointerEvent(type, {
          bubbles: true, cancelable: true, pointerId: 1, clientX: x, clientY: y
        }))
        fire("pointerdown", cx, cy)
        fire("pointermove", cx + #{dx}, cy + #{dy})
        fire("pointerup", cx + #{dx}, cy + #{dy})
      })()
    JS
  end

  # ── The card hero ───────────────────────────────────────────────────────

  test "a Pexels photo — which can never be cropped — can still be repositioned" do
    survey = build_survey([ { "type" => "open_ended", "text" => "Tell us more", "image" => PEXELS_IMAGE } ])
    open_editor(survey)
    assert_text "Tell us more"

    # The CTA is there at all, which it was not before: the old fab was hidden
    # for anything the crop stage couldn't redraw, i.e. for every stock photo.
    find(".survey-card-wrap[data-card-type='open_ended'] .media-adjust-fab").click
    wait_for_pos_stage

    assert_selector "[data-media-picker-target='posCropBtn']", visible: false,
                    count: 1
    refute evaluate_script("document.querySelector(\"[data-media-picker-target='posImg']\").hidden"),
           "a photo is repositioned as a background layer"

    # Drag left: the frame moves right through the picture, so the stored
    # percentage goes UP from centre.
    seed_overflow(200, 0)
    drag_pos_frame(-50, 0)
    click_button "Save position"
    assert_no_selector ".media-modal-backdrop", visible: true

    focal_x = card_dataset("open_ended", "cardFocalX").to_i
    assert_operator focal_x, :>, 50, "dragging left should push the focal point past centre"
    painted = evaluate_script(
      %(document.querySelector(".survey-card-wrap[data-card-type='open_ended'] .split-left-img").style.getPropertyValue("--focal-x"))
    )
    assert_equal "#{focal_x}%", painted, "the live panel must be repainted with what was stored"

    # …and autosave will carry it: the serialiser reads the pair off the row
    # exactly as it reads the image itself.
    serialized = evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="survey-editor"]')
        const c    = app.getControllerForElementAndIdentifier(root, "survey-editor")
        return c.serialize().cards.find(k => k.type === "open_ended")
      })()
    JS
    assert_equal focal_x, serialized["focal_x"],
                 "serialize() dropped focal_x — one autosave would undo the reposition"
  end

  test "a video card offers reposition and no crop at all" do
    survey = build_survey([ { "type" => "open_ended", "text" => "Tell us more", "video" => PEXELS_VIDEO } ])
    open_editor(survey)
    assert_text "Tell us more"

    find(".survey-card-wrap[data-card-type='open_ended'] .media-adjust-fab").click
    wait_for_pos_stage

    # "no crop on the videos" — the hand-off simply isn't offered, and the
    # hint says why rather than leaving a dead control.
    assert_no_selector "[data-media-picker-target='posCropBtn']", visible: true
    assert_selector "[data-media-picker-target='posHintVideo']", visible: true
    assert_no_selector "[data-media-picker-target='posHint']", visible: true
    refute evaluate_script("document.querySelector(\"[data-media-picker-target='posVideo']\").hidden"),
           "a video is previewed as a video, not as a still"

    # Drag up: the frame moves down the clip, so the stored percentage goes up.
    seed_overflow(0, 160)
    drag_pos_frame(0, -40)
    click_button "Save position"
    assert_no_selector ".media-modal-backdrop", visible: true

    focal_y = card_dataset("open_ended", "cardFocalY").to_i
    assert_operator focal_y, :>, 50, "dragging up should push the focal point past centre"
    painted = evaluate_script(
      %(document.querySelector(".survey-card-wrap[data-card-type='open_ended'] .split-left-video").style.getPropertyValue("--focal-y"))
    )
    assert_equal "#{focal_y}%", painted

    serialized = evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="survey-editor"]')
        const c    = app.getControllerForElementAndIdentifier(root, "survey-editor")
        return c.serialize().cards.find(k => k.type === "open_ended")
      })()
    JS
    assert_equal focal_y, serialized["focal_y"],
                 "a video's focal pair has to survive autosave, or the control undoes itself"
    assert_equal PEXELS_VIDEO, serialized["video"]
  end

  test "an axis the frame does not crop cannot be dragged" do
    survey = build_survey([ { "type" => "open_ended", "text" => "Tell us more", "image" => PEXELS_IMAGE } ])
    open_editor(survey)
    assert_text "Tell us more"
    find(".survey-card-wrap[data-card-type='open_ended'] .media-adjust-fab").click
    wait_for_pos_stage

    # Zero overflow is what a picture that exactly fills the frame measures.
    # Moving it would open a gap at the edge, so the drag is a no-op rather
    # than a division by zero flinging the frame to 0% or 100%.
    seed_overflow(0, 0)
    drag_pos_frame(-60, -60)
    click_button "Save position"
    assert_no_selector ".media-modal-backdrop", visible: true

    assert card_dataset("open_ended", "cardFocalX").blank?
    assert card_dataset("open_ended", "cardFocalY").blank?
  end

  test "swapping the picture resets the framing it was chosen for" do
    survey = build_survey([ { "type" => "open_ended", "text" => "Tell us more",
                              "image" => PEXELS_IMAGE, "focal_x" => 20, "focal_y" => 80 } ])
    open_editor(survey)
    assert_text "Tell us more"
    assert_equal "20", card_dataset("open_ended", "cardFocalX")

    evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="media-picker"]')
        const c    = app.getControllerForElementAndIdentifier(root, "media-picker")
        const card = document.querySelector(".survey-card-wrap[data-card-type='open_ended']")
        c._setCardImage(card, #{LIBRARY_IMAGE.to_json})
      })()
    JS

    assert card_dataset("open_ended", "cardFocalX").blank?,
           "a different picture has a different subject — the old framing means nothing against it"
    assert card_dataset("open_ended", "cardFocalY").blank?
    painted = evaluate_script(
      %(document.querySelector(".survey-card-wrap[data-card-type='open_ended'] .split-left-img").style.getPropertyValue("--focal-x"))
    )
    assert_equal "50%", painted, "a stale inline property would frame the new picture by the old one's rules"
  end

  # ── Tap-card statements ─────────────────────────────────────────────────

  test "a statement's image gets its own reposition chip, beside Change image" do
    survey = build_survey([ { "type" => "tap_card", "text" => "Rate these",
                              "options" => [ "One", "Two" ],
                              "option_images" => [ PEXELS_IMAGE, "" ] } ])
    open_editor(survey)
    assert_text "Rate these"

    cards = all(".survey-card-wrap[data-card-type='tap_card'] .rotate-card", visible: :all)
    assert_equal 2, cards.size
    # Only the statement that HAS a picture gets the chip — on the gradient
    # fallback there is nothing to move.
    assert cards[0].has_selector?(".tap-card-adjust-btn", visible: :all)
    assert evaluate_script(
      %(document.querySelectorAll(".rotate-card")[1].querySelector(".tap-card-adjust-btn").hidden)
    ), "a statement with no picture must not offer to reposition one"

    evaluate_script(%(document.querySelectorAll(".rotate-card")[0].querySelector(".tap-card-adjust-btn").click()))
    wait_for_pos_stage

    seed_overflow(0, 120)
    drag_pos_frame(0, 30)
    click_button "Save position"
    assert_no_selector ".media-modal-backdrop", visible: true

    focals = JSON.parse(card_dataset("tap_card", "cardOptionFocals"))
    assert_equal 1, focals.length, "trailing untouched statements are stored as nothing"
    assert_operator focals[0]["y"], :<, 50, "dragging down should pull the focal point above centre"

    painted = evaluate_script(<<~JS)
      (() => {
        const el = document.querySelectorAll(".rotate-card")[0].querySelector(".rotate-card-media")
        return [ el.style.getPropertyValue("--focal-x"), el.style.getPropertyValue("--focal-y") ]
      })()
    JS
    assert_equal [ "#{focals[0]['x']}%", "#{focals[0]['y']}%" ], painted,
                 "the statement's live media layer must be repainted with what was stored"

    serialized = evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="survey-editor"]')
        const c    = app.getControllerForElementAndIdentifier(root, "survey-editor")
        return c.serialize().cards.find(k => k.type === "tap_card")
      })()
    JS
    assert_equal focals, serialized["option_focals"],
                 "serialize() dropped option_focals — one autosave would undo the reposition"
  end

  # option_focals is positional against option_images, and deleting a statement
  # removes its node without renumbering. Left unspliced, every statement after
  # the deleted one inherits the framing of the one before it — invisible until
  # a reload, by which time the deck has been saved. Same bug option_images
  # already had (BUG log, "removing statement 1 of 5 left images 1-4 against").
  test "deleting a statement takes its reposition with it" do
    survey = build_survey([ { "type" => "tap_card", "text" => "Rate these",
                              "options" => [ "One", "Two", "Three" ],
                              "option_images" => [ PEXELS_IMAGE, PEXELS_IMAGE, PEXELS_IMAGE ],
                              "option_focals" => [ nil, { "x" => 10, "y" => 10 }, { "x" => 90, "y" => 90 } ] } ])
    open_editor(survey)
    assert_text "Rate these"
    assert_equal 3, JSON.parse(card_dataset("tap_card", "cardOptionFocals")).length

    evaluate_script(%(document.querySelectorAll(".rotate-card")[0].querySelector(".tap-card-delete").click()))

    focals = JSON.parse(card_dataset("tap_card", "cardOptionFocals"))
    assert_equal [ { "x" => 10, "y" => 10 }, { "x" => 90, "y" => 90 } ], focals,
                 "the array must shift with the statements, not stay put and re-point"
    images = JSON.parse(card_dataset("tap_card", "cardOptionImages"))
    assert_equal 2, images.length
  end

  # ── Zoom: what makes an axis that already fits movable at all ───────────
  # With cover-fit, an axis where the picture's shape matches the frame hides
  # nothing — so a drag there has nothing to reveal, however hard you pull.
  # That is the "I can't move it vertically" report. Punching in past cover-fit
  # hides some of BOTH axes, and both then move.

  test "zooming in gives an already-fitting axis something to slide" do
    survey = build_survey([ { "type" => "open_ended", "text" => "Tell us more", "image" => PEXELS_IMAGE } ])
    open_editor(survey)
    assert_text "Tell us more"
    find(".survey-card-wrap[data-card-type='open_ended'] .media-adjust-fab").click
    wait_for_pos_stage

    # A picture that exactly fills the frame: nothing hidden on either axis.
    seed_natural_matching_frame
    assert_equal [ 0, 0 ], pos_overflow.map(&:round),
                 "a picture matching the frame hides nothing at cover-fit — that is the bug being fixed"

    # The slider is the fix: at 2x, both axes have slack.
    find("[data-media-picker-target='posZoom']").set(2)
    ox, oy = pos_overflow
    assert_operator ox, :>, 0, "zooming in must open up the horizontal axis"
    assert_operator oy, :>, 0, "…and the vertical one, which is the axis that was stuck"

    drag_pos_frame(0, -40)
    click_button "Save position"
    assert_no_selector ".media-modal-backdrop", visible: true

    assert_operator card_dataset("open_ended", "cardFocalY").to_i, :>, 50,
                    "the vertical drag has to move the frame now"
    assert_equal "2", card_dataset("open_ended", "cardFocalZoom")
    painted = evaluate_script(
      %(document.querySelector(".survey-card-wrap[data-card-type='open_ended'] .split-left-img").style.getPropertyValue("--focal-zoom"))
    )
    assert_equal "2", painted, "the live panel must be repainted at the stored zoom"

    serialized = evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="survey-editor"]')
        const c    = app.getControllerForElementAndIdentifier(root, "survey-editor")
        return c.serialize().cards.find(k => k.type === "open_ended")
      })()
    JS
    assert_equal 2, serialized["focal_zoom"],
                 "serialize() dropped focal_zoom — one autosave would snap the picture back to fit"
  end

  test "winding the zoom back to cover-fit stores nothing" do
    survey = build_survey([ { "type" => "open_ended", "text" => "Tell us more",
                              "image" => PEXELS_IMAGE, "focal_zoom" => 2.5 } ])
    open_editor(survey)
    assert_text "Tell us more"
    assert_equal "2.5", card_dataset("open_ended", "cardFocalZoom")

    find(".survey-card-wrap[data-card-type='open_ended'] .media-adjust-fab").click
    wait_for_pos_stage
    # The stage reopens AT the stored zoom, not reset to fit.
    assert_equal "2.5", find("[data-media-picker-target='posZoom']").value

    find("[data-media-picker-target='posZoom']").set(1)
    click_button "Save position"
    assert_no_selector ".media-modal-backdrop", visible: true
    assert card_dataset("open_ended", "cardFocalZoom").blank?,
           "cover-fit is the default — storing it stores nothing"
  end

  # ── "Where do the options sit?" ─────────────────────────────────────────
  # A statement's picture is never seen bare: the statement band covers its top
  # and the response strip its bottom. Framing a face into either is the one
  # mistake you cannot see until you play the deck.

  test "the reposition stage shows the statement band and answer strip over the picture" do
    survey = build_survey([ { "type" => "tap_card", "text" => "Rate these",
                              "options" => [ "One", "Two" ],
                              "option_images" => [ PEXELS_IMAGE, PEXELS_IMAGE ] } ])
    open_editor(survey)
    assert_text "Rate these"

    evaluate_script(%(document.querySelectorAll(".rotate-card")[0].querySelector(".tap-card-adjust-btn").click()))
    wait_for_pos_stage

    ghosts = all("[data-media-picker-target='posChrome'] .media-pos-ghost", visible: :all)
    assert_equal 2, ghosts.size, "both the statement band and the answer strip should be drawn"
    labels = ghosts.map { |g| g.text(:all).strip }
    assert_includes labels, "Statement"
    assert_includes labels, "Answers"

    # Drawn from the LIVE card's measurements, so it stays true as the strip
    # changes shape with the answer count — the band sits at the top, the
    # answers at the bottom, and neither is a full-height guess.
    tops = evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("[data-media-picker-target='posChrome'] .media-pos-ghost"))
           .map(el => parseFloat(el.style.top))
    JS
    assert_operator tops.min, :<, 20, "the statement band belongs near the top of the frame"
    assert_operator tops.max, :>, 20, "the answer strip belongs below it"
  end

  test "a card hero gets no ghost — nothing of the card sits over it" do
    survey = build_survey([ { "type" => "open_ended", "text" => "Tell us more", "image" => PEXELS_IMAGE } ])
    open_editor(survey)
    assert_text "Tell us more"
    find(".survey-card-wrap[data-card-type='open_ended'] .media-adjust-fab").click
    wait_for_pos_stage

    assert_no_selector "[data-media-picker-target='posChrome']", visible: true
  end

  # The chip's index used to be baked into the markup, and deleting a statement
  # renumbered nothing — so after one delete every chip pointed one statement
  # further along than the one it sat on.
  test "a statement chip still targets its own statement after a delete" do
    survey = build_survey([ { "type" => "tap_card", "text" => "Rate these",
                              "options" => [ "One", "Two", "Three" ],
                              "option_images" => [ PEXELS_IMAGE, PEXELS_IMAGE, PEXELS_IMAGE ] } ])
    open_editor(survey)
    assert_text "Rate these"

    evaluate_script(%(document.querySelectorAll(".rotate-card")[0].querySelector(".tap-card-delete").click()))
    # What was statement 3 is now statement 2 — and its chip must reframe it,
    # not the statement that used to hold index 2.
    evaluate_script(%(document.querySelectorAll(".rotate-card")[1].querySelector(".tap-card-adjust-btn").click()))
    wait_for_pos_stage

    index = evaluate_script(<<~JS)
      (() => {
        const app  = window.Stimulus || window.application
        const root = document.querySelector('[data-controller~="media-picker"]')
        return app.getControllerForElementAndIdentifier(root, "media-picker")._posSlot.index
      })()
    JS
    assert_equal 1, index, "the slot must come from DOM order, not from a stale baked index"
  end
end
