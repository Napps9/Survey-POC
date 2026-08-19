require "application_system_test_case"

# BUG-026. A tap card's `option_images` are POSITIONAL — image[i] belongs to
# statement[i] — and `serialize()` bounds the array by truncating its TAIL.
# `deleteOption` removed the statement's DOM node without removing its image, so
# every picture after the deleted one shifted up onto the wrong statement.
#
# Nothing looked wrong at the time: the backgrounds are inline on the surviving
# nodes, so the screen stayed correct while the array being saved did not. The
# mismatch only appeared after a reload — by which point the deck had been saved
# and the original alignment was gone.
class TapCardImagesTest < ApplicationSystemTestCase
  # option_images are plain URL strings — sanitize_image_url takes a URL, and a
  # hash here is scrubbed to nil.
  IMAGES = (1..4).map { |i| "https://images.pexels.com/photos/#{i}/x.jpg" }.freeze
  STATEMENTS = [ "Statement one", "Statement two", "Statement three", "Statement four" ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "tc-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Tc", email_address: "tc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Tap", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "tap_card", "cid" => "t1", "text" => "Swipe these",
          "options" => STATEMENTS.dup, "option_images" => IMAGES.dup }
      ]
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_selector "[data-card-cid='t1'] .rotate-card", minimum: 2
  end

  # Delete the statement at `index` via its own × button, the way a creator does.
  def delete_statement(index)
    ok = evaluate_script(<<~JS)
      (() => {
        const cards = document.querySelectorAll("[data-card-cid='t1'] .rotate-card")
        const btn = cards[#{index}]?.querySelector("[data-action*='card-editor#deleteOption']")
        if (!btn) return false
        btn.click()
        return true
      })()
    JS
    assert ok, "no delete button on statement #{index}"
  end

  def stored_card
    @survey.reload.cards.find { |c| c["cid"] == "t1" }
  end

  test "deleting the first statement takes its picture with it" do
    open_editor
    delete_statement(0)

    Timeout.timeout(15) { sleep 0.25 until stored_card["options"].size == 3 }

    card = stored_card
    assert_equal STATEMENTS.drop(1), card["options"]
    assert_equal IMAGES.drop(1), card["option_images"],
                 "each remaining statement kept the picture belonging to the one before it"
  end

  test "deleting a middle statement keeps the rest aligned" do
    open_editor
    delete_statement(1)

    Timeout.timeout(15) { sleep 0.25 until stored_card["options"].size == 3 }

    card = stored_card
    assert_equal [ STATEMENTS[0], STATEMENTS[2], STATEMENTS[3] ], card["options"]
    assert_equal [ IMAGES[0], IMAGES[2], IMAGES[3] ], card["option_images"]
  end

  test "deleting the last statement leaves the others untouched" do
    # The one case the old code got right — truncating from the tail happens to
    # be correct when the tail is what was deleted. Worth pinning so a fix that
    # over-corrects is caught too.
    open_editor
    delete_statement(3)

    Timeout.timeout(15) { sleep 0.25 until stored_card["options"].size == 3 }

    card = stored_card
    assert_equal STATEMENTS.first(3), card["options"]
    assert_equal IMAGES.first(3), card["option_images"]
  end

  # 19 Aug: "the push wiped my assets" turned out not to be data loss (a hard
  # refresh brought everything back) — but chasing it surfaced a REAL, if
  # unconfirmed-in-the-wild, footgun next to this one: serialize() bounds
  # option_images to the number of statement nodes _optionEls() finds, and if
  # that selector ever misses on a genuine tap_card (nothing found, rather
  # than nothing to find), the bound is 0 and every image is wiped — silently,
  # same as the deletion bug above, just total instead of partial. This forces
  # that miss directly rather than waiting to reproduce whatever would cause
  # it live.
  test "a statement-selector miss carries option_images through instead of wiping them" do
    open_editor
    before = @survey.updated_at

    ok = evaluate_script(<<~JS)
      (() => {
        const spans = document.querySelectorAll("[data-card-cid='t1'] .rotate-card span[contenteditable]")
        if (!spans.length) return false
        spans.forEach(s => s.removeAttribute("contenteditable"))
        const editorEl = document.querySelector('[data-controller~="survey-editor"]')
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(editorEl, "survey-editor")
        if (!ctrl) return false
        ctrl.markDirty()
        return true
      })()
    JS
    assert ok, "expected statement spans and the survey-editor controller on the page"

    Timeout.timeout(15) { sleep 0.25 while @survey.reload.updated_at == before }

    assert_equal IMAGES, stored_card["option_images"],
                 "a statement-selector miss must not truncate option_images to empty"
  end
end
