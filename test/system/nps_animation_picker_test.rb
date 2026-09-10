require "application_system_test_case"

# Picking an NPS card's animation.
#
# A Range card's animation is a reaction character and has had a picker for a
# while. An NPS card's animation is the liquid CONTAINER it fills, and it had
# none: the vessel was derived from the Verto's theme and that was the end of
# it, so two NPS cards in one Verto could only ever be the same shape and no
# creator could say otherwise.
#
# The whole path in one test, because every link in it is somewhere the value
# can be dropped silently: the CTA has to reach the right pane, the pick has to
# redraw the vessel client-side (lib/nps_vessels, a mirror of the Ruby that drew
# what is on screen), the redraw has to move the stage's geometry with it or the
# digits stop lining up with the fill, and the card has to still be carrying the
# pick after the autosave round-trip.
class NpsAnimationPickerTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Vess", slug: "vess-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Vess", email_address: "vess-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
    # "Coffee culture" resolves to the mug — a themed default, so the test can
    # tell "the creator's pick" apart from "whatever the theme would have done".
    @survey = @org.surveys.create!(
      title: "Vess", theme: "Coffee culture", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "nps", "cid" => "n1", "text" => "How likely?" }
      ]
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "How likely?"
  end

  def card_shape
    evaluate_script(<<~JS)
      (() => {
        const wrap  = document.querySelector("[data-card-cid='n1']")
        const ctrl  = wrap.querySelector(".nps-control")
        const stage = wrap.querySelector(".nps-slider-stage")
        return {
          klass:   ctrl ? ctrl.className : "",
          aspect:  stage ? stage.style.getPropertyValue("--nps-aspect").trim() : "",
          travel:  stage ? stage.style.getPropertyValue("--nps-travel").trim() : "",
          select:  wrap.querySelector(".nps-shape-select")?.value || "",
          dataset: wrap.dataset.cardNpsShape || ""
        }
      })()
    JS
  end

  test "the themed default is what an untouched card draws" do
    open_editor
    assert_includes card_shape["klass"], "nps-shape-mug",
                    "an NPS card no longer follows the Verto's theme when it has made no pick " \
                    "of its own"
    assert_equal "", card_shape["dataset"],
                 "an untouched card is carrying a stored shape — its absence is what keeps it " \
                 "following the theme"
  end

  test "picking a container redraws the card and survives the save" do
    open_editor
    find("[data-card-cid='n1'] .add-animation-fab").click
    assert_selector ".anim-modal [data-animation-picker-target='shapePane'] .anim-option-shape",
                    visible: true, wait: 5

    before = card_shape
    find(".anim-option-shape[data-slug='flask']").click
    assert_no_selector ".anim-modal", visible: true, wait: 3

    after = card_shape
    assert_includes after["klass"], "nps-shape-flask", "the card did not redraw to the pick"
    assert_equal "flask", after["select"], "the hidden apply path is out of step with the card"
    assert_equal "flask", after["dataset"],
                 "the pick was not recorded on the card row, so the autosave will not carry it"

    # The stage's custom properties ARE the vessel's geometry — where its liquid
    # sits empty and full, and the inset the digit column is positioned by. A
    # redraw that swapped the silhouette and left these behind would look right
    # and put every number beside the wrong fill level.
    refute_equal before["aspect"], after["aspect"],
                 "the stage still carries the previous vessel's aspect ratio"
    refute_equal before["travel"], after["travel"],
                 "the stage still carries the previous vessel's fill travel, so the labels no " \
                 "longer line up with the liquid"

    # Poll the deck rather than the status chip: the chip READS "Saved" before
    # anything has been edited, so waiting on its text passes instantly and
    # measures nothing. Autosave is debounced ~1.5s.
    stored = nil
    30.times do
      stored = @survey.reload.cards.find { |c| c["cid"] == "n1" }["nps_shape"]
      break if stored
      sleep 0.5
    end
    assert_equal "flask", stored, "the pick did not reach the deck"
  end

  test "the picker opens on the container the card is currently drawing" do
    open_editor
    find("[data-card-cid='n1'] .add-animation-fab").click
    assert_selector ".anim-modal [data-animation-picker-target='shapePane']", visible: true, wait: 5

    selected = evaluate_script(<<~JS)
      Array.from(document.querySelectorAll(".anim-option-shape[aria-selected='true']"))
           .map(el => el.dataset.slug)
    JS
    assert_equal [ "mug" ], selected,
                 "the picker does not tick the shape the card is drawing, so a creator cannot " \
                 "tell what they already have"
  end

  # The Range card's own picker shares this modal and must keep its own pane.
  test "a range card still opens the character picker, not the containers" do
    @survey.update!(cards: @survey.cards + [
      { "type" => "range", "cid" => "r1", "text" => "How much?", "options" => %w[1 2 3 4 5] }
    ])
    open_editor
    find("[data-card-cid='r1'] .add-animation-fab").click

    assert_selector ".anim-modal [data-animation-picker-target='lottiePane'] .anim-option",
                    visible: true, wait: 5
    assert_no_selector ".anim-modal [data-animation-picker-target='shapePane']", visible: true
  end
end
