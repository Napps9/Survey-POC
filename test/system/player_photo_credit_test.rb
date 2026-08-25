require "application_system_test_case"

# The Pexels creator credit, and the strip of hero it has to stay out of.
#
# On mobile the answer panel deliberately rides UP over the hero's lower edge
# and rounds its top corners, so the two stop reading as two separate things.
# The credit is positioned against that same lower edge — and was positioned
# 12px off it, which is INSIDE the 22px the panel covers. So on every mobile
# card carrying a photo, the credit was painted over and sheared off mid-word:
# an attribution that is legally the point of showing it, rendered unreadable.
#
# Not a z-index problem, which is why it survived review: the credit is
# z-index 2 against the panel's 1. The panel simply paints a background over
# the part of the hero the credit was sitting on.
#
# The two numbers are one number now (--play-lip), and this measures the thing
# that actually matters rather than the token: the credit's box must END above
# where the panel BEGINS. A future retune of the lip moves both together and
# this stays green; a retune of only one is exactly the bug, and fails here.
class PlayerPhotoCreditTest < ApplicationSystemTestCase
  # The SE is included because it is the shortest ordinary phone and crosses
  # into the short-viewport tier, where the hero is at its slimmest and the
  # credit has least room to be wrong in.
  PHONES  = { "iPhone 15" => [ 393, 852 ], "iPhone SE" => [ 375, 667 ] }.freeze
  DESKTOP = [ 1280, 900 ].freeze

  CARDS = [
    { "type" => "welcome_card", "title" => "Hi" },
    { "type" => "multiple_choice", "cid" => "m1", "text" => "Which of these?",
      "image" => "/nope.jpg",
      "image_credit" => "Muhammad-Taha Ibrahim",
      "image_credit_url" => "https://example.com/photographer",
      "options" => [ "Alpha", "Beta", "Gamma" ] }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "credit-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Credit", theme: "T", audience_age: "all",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  # Cuprite keeps ONE browser for the whole run, so a suite that exits
  # phone-sized breaks every test scheduled after it.
  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_photo_card(width:, height:)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"
    sleep 0.5
    assert_equal "multiple_choice", find(".preview-card.active")["data-card-type"]
  end

  # Positive number = that many pixels of the credit are underneath the panel.
  def credit_overlap
    page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        const cr = card && card.querySelector(".split-left-credit")
        const sr = card && card.querySelector(".split-right")
        if (!cr || !sr) return null
        return +(cr.getBoundingClientRect().bottom - sr.getBoundingClientRect().top).toFixed(1)
      })()
    JS
  end

  PHONES.each do |name, (w, h)|
    test "the photo credit is not painted over by the answer panel on an #{name}" do
      open_photo_card(width: w, height: h)

      overlap = credit_overlap
      assert overlap, "no credit rendered on a card that carries image_credit"
      assert_operator overlap, :<, 0,
                      "#{overlap}px of the photo credit is underneath the answer panel. The " \
                      "panel rides --play-lip up over the hero's bottom edge; anything " \
                      "positioned against that edge has to clear the lip, not sit inside it."
    end
  end

  # The credit is an attribution, so "moved it out from under the panel" is only
  # half an answer — it also has to still be ON the picture. Pushed too far it
  # would climb off the hero entirely, or on a short phone collide with the
  # progress bar pinned to the hero's top.
  test "the credit stays inside the hero it credits" do
    open_photo_card(width: PHONES["iPhone SE"][0], height: PHONES["iPhone SE"][1])

    box = page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        const cr = card.querySelector(".split-left-credit")
        const sl = card.querySelector(".split-left")
        const pb = card.querySelector(".panel-progress")
        const r = (el) => { const b = el.getBoundingClientRect(); return { top: b.top, bottom: b.bottom } }
        return { credit: r(cr), hero: r(sl), progressBottom: pb ? r(pb).bottom : null }
      })()
    JS

    assert_operator box["credit"]["top"], :>, box["hero"]["top"],
                    "the credit has climbed off the top of the hero"
    assert_operator box["credit"]["bottom"], :<=, box["hero"]["bottom"] + 1,
                    "the credit is below the hero it credits"
    if box["progressBottom"]
      assert_operator box["credit"]["top"], :>, box["progressBottom"],
                      "the credit is overlapping the progress bar"
    end
  end
end
