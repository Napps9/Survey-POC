require "application_system_test_case"

# Postcode capture (Survey#capture_postcode?) end to end: the editor toggle,
# the extra field it adds to the "Where do you live?" card, and the packed
# answer it produces in either fill-in order (postcode-then-pick and
# pick-then-postcode both have to land on the same value) — see
# PlayerController#sync_region_from_answers! for the matching three-segment
# parse this feeds.
class PostcodeCaptureTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "open_ended", "input" => "location", "text" => "Where do you live?", "demographic" => true }
  ].freeze

  def setup
    super
    @user = User.create!(name: "U", email_address: "pc-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org = Organisation.create!(name: "O", slug: "pc-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
  end

  def draft_survey(capture_postcode: false)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: CARDS,
                         capture_postcode: capture_postcode)
  end

  # The checkbox lives inside the "Audience" <details> panel, itself inside
  # the "Publish & share" right-column tab — hidden until that tab opens.
  # .trigger("click") throughout: a live Verto shows a warning overlay that
  # sits over the same coordinates as the trigger button/summary.
  def open_audience_panel
    find_button("Publish & share", wait: 5).trigger("click")
    assert_selector ".publish-panel:not(.hidden)", wait: 5
    # .publish-block-title renders upper-cased via CSS text-transform — the
    # rendered (and Capybara-matched) text is "AUDIENCE", not the DOM
    # source's "Audience".
    find("summary", text: /audience/i, wait: 5).trigger("click")
  end

  test "the editor toggle turns the postcode field on and off" do
    s = draft_survey
    sign_in_as(@user)
    visit survey_path(s)
    dismiss_cookie_banner
    open_audience_panel

    checkbox = find("input[name='capture_postcode']:not([type=hidden])")
    refute checkbox.checked?
    checkbox.click

    Timeout.timeout(10) { sleep 0.2 until s.reload.capture_postcode? }
    assert s.capture_postcode?
  end

  test "the toggle is disabled once the Verto is live" do
    s = draft_survey
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    sign_in_as(@user)
    visit survey_path(s)
    dismiss_cookie_banner
    open_audience_panel

    assert_selector "input[name='capture_postcode'][disabled]"
  end

  test "off by default: the location card has no postcode field" do
    s = draft_survey(capture_postcode: false)
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    visit "/play/#{s.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"

    assert_selector ".location-search-field", wait: 5
    assert_no_selector ".location-postcode-field"
  end

  # The search itself talks to a real Nominatim proxy this test does not
  # stand up, so the pick is simulated directly on the hidden value target —
  # exactly the state _pick() leaves behind (country|label, no postcode yet)
  # — and the postcode is typed through Capybara for a REAL input event, so
  # this is a genuine test of postcodeChanged()'s repack, not of the network.
  test "typing a postcode after a location is picked packs all three segments" do
    s = draft_survey(capture_postcode: true)
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    visit "/play/#{s.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"
    assert_selector ".location-postcode-field", wait: 5

    evaluate_script(<<~JS)
      document.querySelector('.location-search-value').value = 'GB|Bristol'
    JS
    find(".location-postcode-field").set("BS1 4DJ")

    assert_equal "GB|Bristol|BS1 4DJ",
      evaluate_script("document.querySelector('.location-search-value').value")
  end

  # The other fill-in order: a postcode typed before anything is picked must
  # not be silently discarded — the field's own value survives, and the
  # eventual pick (_pick, not postcodeChanged) packs it in.
  test "typing a postcode before picking a location does not block the pick from packing it in" do
    s = draft_survey(capture_postcode: true)
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    visit "/play/#{s.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"
    assert_selector ".location-postcode-field", wait: 5

    find(".location-postcode-field").set("BS1 4DJ")
    assert_equal "", evaluate_script("document.querySelector('.location-search-value').value"),
      "a postcode alone, with nothing picked yet, must not pack anything"

    # _pick's own code path (not postcodeChanged) is what has to pick the
    # postcode up here — call it the way a real result click would.
    evaluate_script(<<~JS)
      (() => {
        const app = window.Stimulus || window.application
        const el = document.querySelector('[data-controller~="location-search"]')
        const controller = app.getControllerForElementAndIdentifier(el, "location-search")
        controller._results = [ { country_code: "GB", label: "Bristol", display_name: "Bristol, UK" } ]
        controller._pick(0)
      })()
    JS

    assert_equal "GB|Bristol|BS1 4DJ",
      evaluate_script("document.querySelector('.location-search-value').value")
  end
end
